# GitHub Actions authenticates by exchanging a short-lived OIDC token for AWS credentials. No
# access keys are stored in GitHub, so there is nothing in the repo or its secrets to leak, rotate
# or revoke.
#
# The three roles mirror the three pipeline stages. Splitting them is what makes the blast radius
# of a compromised workflow bounded: a tampered CI job can read, but it cannot push an image or
# change infrastructure.

data "aws_caller_identity" "current" {}

locals {
  oidc_host    = "token.actions.githubusercontent.com"
  state_bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://${local.oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Trust is granted per subject claim rather than to the repository as a whole.
#   pull_request      -> CI only, and never on a fork's terms
#   ref:refs/heads/*  -> release, which must come from a branch we control
#   environment:*     -> deploy, so the GitHub environment approval gate sits in front of the
#                        credentials themselves rather than merely in front of the job
data "aws_iam_policy_document" "assume_role" {
  for_each = {
    ci = [
      "repo:${var.github_repository}:pull_request",
      "repo:${var.github_repository}:ref:${var.protected_prod_ref}",
    ]
    release = [
      "repo:${var.github_repository}:ref:${var.protected_prod_ref}",
      "repo:${var.github_repository}:ref:refs/tags/v*",
    ]
    deployment = [
      "repo:${var.github_repository}:environment:dev",
      "repo:${var.github_repository}:environment:prod",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Without the audience check the role would trust tokens minted for any other service.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "ci" {
  name                 = "${var.project}-role-cipipeline"
  description          = "Lint, test and terraform plan. Read-only."
  assume_role_policy   = data.aws_iam_policy_document.assume_role["ci"].json
  max_session_duration = 3600
}

resource "aws_iam_role" "release" {
  name                 = "${var.project}-role-releasepipeline"
  description          = "Build and push container images. ECR write only, no deploy."
  assume_role_policy   = data.aws_iam_policy_document.assume_role["release"].json
  max_session_duration = 3600
}

resource "aws_iam_role" "deployment" {
  name                 = "${var.project}-role-deploymentpipeline"
  description          = "terraform apply and ECS/CodeDeploy releases."
  assume_role_policy   = data.aws_iam_policy_document.assume_role["deployment"].json
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# CI — reads everything, changes nothing
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ci" {
  statement {
    sid    = "TerraformStateReadAndLock"
    effect = "Allow"
    # plan takes a lock, so it writes the lockfile object even though it changes no infrastructure.
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*"]
  }

  statement {
    sid       = "TerraformStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }

  # ReadOnlyAccess is broad enough to read secret material, which a CI job never needs. The deny
  # wins over the managed policy regardless of what AWS adds to it later.
  statement {
    sid       = "NeverReadSecretMaterial"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "state-and-guardrails"
  role   = aws_iam_role.ci.id
  policy = data.aws_iam_policy_document.ci.json
}

resource "aws_iam_role_policy_attachment" "ci_readonly" {
  role       = aws_iam_role.ci.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---------------------------------------------------------------------------
# Release — pushes images and nothing else
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "release" {
  statement {
    sid    = "EcrLogin"
    effect = "Allow"
    # GetAuthorizationToken is account-wide by design; it cannot be scoped to a repository.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushToProjectRepositoriesOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [for repo in aws_ecr_repository.component : repo.arn]
  }
}

resource "aws_iam_role_policy" "release" {
  name   = "ecr-push"
  role   = aws_iam_role.release.id
  policy = data.aws_iam_policy_document.release.json
}

# ---------------------------------------------------------------------------
# Deployment — the only role that changes anything
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deployment" {
  statement {
    sid       = "TerraformState"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/*"]
  }

  statement {
    sid       = "TerraformStateList"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
  }

  # PowerUserAccess deliberately excludes IAM, so the role's own permissions are granted back here
  # narrowly: it can manage roles this project owns and nothing else. Without the name constraint,
  # a compromised deploy job could mint itself an administrator.
  statement {
    sid    = "ManageProjectIamOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:CreateServiceLinkedRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*",
    ]
  }

  statement {
    sid       = "PassProjectRolesToServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com", "codedeploy.amazonaws.com"]
    }
  }

  # The pipeline roles and the identity provider are this layer's own foundations. Letting the
  # deploy role rewrite them would make the three-role split cosmetic.
  statement {
    sid    = "NeverAlterOwnFoundations"
    effect = "Deny"
    actions = [
      "iam:*OpenIDConnectProvider*",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRole",
    ]
    resources = [
      aws_iam_role.ci.arn,
      aws_iam_role.release.arn,
      aws_iam_role.deployment.arn,
      aws_iam_openid_connect_provider.github.arn,
    ]
  }
}

resource "aws_iam_role_policy" "deployment" {
  name   = "deploy"
  role   = aws_iam_role.deployment.id
  policy = data.aws_iam_policy_document.deployment.json
}

resource "aws_iam_role_policy_attachment" "deployment_poweruser" {
  role       = aws_iam_role.deployment.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
