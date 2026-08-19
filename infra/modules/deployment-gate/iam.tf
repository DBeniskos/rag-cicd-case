# Two roles again, for the same reason as the service: the identity that *runs* the gate and the
# identity that *calls* it are different principals with different blast radii.

data "aws_iam_policy_document" "assume_lambda" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gate" {
  name               = "${var.name_prefix}-deployment-gate"
  description        = "Runs the release quality gate during a deployment."
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

resource "aws_iam_role_policy_attachment" "gate_logs" {
  role       = aws_iam_role.gate.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# The gate calls an authenticated endpoint, so it needs the key and nothing else. It has no
# Bedrock, S3 or ECS permission: it observes a release, it cannot alter one.
resource "aws_iam_role_policy" "gate_secret" {
  name = "read-api-key"
  role = aws_iam_role.gate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadApiKeyOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.api_key_secret_arn]
      },
      {
        # DescribeLoadBalancers takes no resource-level condition; it is read-only and returns
        # nothing sensitive.
        Sid      = "ResolveTestListener"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeLoadBalancers"]
        Resource = ["*"]
      },
    ]
  })
}

data "aws_iam_policy_document" "assume_ecs" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "invoke" {
  name               = "${var.name_prefix}-gate-invoke"
  description        = "Assumed by ECS to call the deployment gate."
  assume_role_policy = data.aws_iam_policy_document.assume_ecs.json
}

resource "aws_iam_role_policy" "invoke" {
  name = "invoke-gate"
  role = aws_iam_role.invoke.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeThisGateOnly"
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = [aws_lambda_function.gate.arn]
    }]
  })
}
