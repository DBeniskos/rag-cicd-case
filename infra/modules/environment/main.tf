# One environment, assembled from the reusable modules.
#
# This layer exists so dev and prod are the *same* code with different inputs. If each
# environment wired the modules itself, they would drift, and non-prod would stop being a
# rehearsal for prod — which is the only reason non-prod is worth paying for.

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id

  staged_rollout = var.deployment_strategy != "ROLLING"

  # Built from the known role name rather than read from module.api, which would make the secret
  # depend on the service that consumes it and close a dependency cycle.
  execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-${var.environment}-task-execution"

  # Same reason: the gate reads the key, and the secret names the roles that may read it.
  gate_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-deployment-gate"

  secret_reader_arns = local.staged_rollout ? [local.execution_role_arn, local.gate_role_arn] : [local.execution_role_arn]
}

module "network" {
  source = "../network"

  name_prefix    = local.name_prefix
  cidr_block     = var.cidr_block
  container_port = var.container_port
  ingress_cidrs  = var.ingress_cidrs

  test_listener_port = local.staged_rollout ? 8080 : 0
  test_ingress_cidrs = var.test_ingress_cidrs
}

# Somewhere for an alarm to go. Without this the alarms still fail a deployment — ECS polls them
# directly — but nobody is told that a release was reversed, which is how a rollback becomes a
# surprise the next morning.
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# AWS emails a confirmation link that has to be clicked; until then the subscription is pending
# and delivers nothing.
resource "aws_sns_topic_subscription" "alerts_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch could publish here on the default policy; EventBridge cannot. Setting a policy at all
# replaces the default, so the owner statement has to be restated or the account loses the ability
# to manage its own topic — including the subscription Terraform just created.
data "aws_iam_policy_document" "alerts" {
  statement {
    sid    = "OwnerManagesTopic"
    effect = "Allow"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AlarmsAndDeploymentEventsPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts.json
}

module "index_store" {
  source = "../index-store"

  name_prefix          = local.name_prefix
  environment          = var.environment
  account_id           = local.account_id
  index_retention_days = var.index_retention_days
  # Prod keeps its corpus and indexes even if someone runs destroy by mistake.
  force_destroy = var.environment != "prod"
}

# The ALB is public, so /ask is authenticated with a key the caller presents. Secrets Manager holds
# the value; nothing in this repo, in CI or in the task definition ever does.
module "api_key_secret" {
  source = "../secret"

  name_prefix        = local.name_prefix
  secret_envvar_name = "RAG_API_KEY"
  project            = var.project
  environment        = var.environment

  # Prod keeps a recovery window so a mistaken destroy is reversible.
  recovery_window_days = var.environment == "prod" ? 7 : 0

  # Named explicitly, so the resource policy is a second independent grant rather than relying on
  # the execution role's own policy being the only control.
  allowed_roles_arn = local.secret_reader_arns
}

# The release gate. It only exists where there is a test listener to validate: a rolling update
# replaces tasks in place, so there is no second endpoint to judge before traffic reaches it.
module "deployment_gate" {
  count  = local.staged_rollout ? 1 : 0
  source = "../deployment-gate"

  name_prefix = local.name_prefix
  environment = var.environment
  account_id  = local.account_id

  alb_name           = "${local.name_prefix}-alb"
  test_port          = 8080
  api_key_secret_arn = module.api_key_secret.arn

  timeout_seconds    = var.gate_timeout_seconds
  log_retention_days = var.log_retention_days
}

module "api" {
  source = "../ecs-service"

  name_prefix = local.name_prefix
  environment = var.environment
  region      = var.region
  account_id  = local.account_id

  vpc_id                  = module.network.vpc_id
  subnet_ids              = module.network.public_subnet_ids
  alb_security_group_id   = module.network.alb_security_group_id
  tasks_security_group_id = module.network.tasks_security_group_id

  image           = var.image
  container_port  = var.container_port
  cpu             = var.cpu
  memory          = var.memory
  desired_count   = var.desired_count
  release_version = var.release_version
  git_sha         = var.git_sha

  deployment_strategy = var.deployment_strategy
  bake_time_minutes   = var.bake_time_minutes
  docs_servers        = var.docs_servers

  gate_hook_target_arn = try(module.deployment_gate[0].function_arn, "")
  gate_hook_role_arn   = try(module.deployment_gate[0].invoke_role_arn, "")

  error_count_threshold         = var.error_count_threshold
  latency_p95_threshold_seconds = var.latency_p95_threshold_seconds
  latency_p99_threshold_seconds = var.latency_p99_threshold_seconds
  alarm_topic_arn               = aws_sns_topic.alerts.arn

  index_bucket_arn            = module.index_store.bucket_arn
  index_bucket_name           = module.index_store.bucket_name
  active_index_parameter_arn  = module.index_store.active_index_parameter_arn
  active_index_parameter_name = module.index_store.active_index_parameter_name
  active_index_version        = var.active_index_version

  embed_model_id    = var.embed_model_id
  text_model_id     = var.text_model_id
  max_output_tokens = var.max_output_tokens

  container_secrets = [module.api_key_secret.container_secret]
  secret_arns       = [module.api_key_secret.arn]

  log_retention_days = var.log_retention_days
}

# The ingestion job exists in every environment, because an index has to be built where it will be
# served: the same corpus embedded by the same model, written to that environment's own bucket.
module "ingest" {
  source = "../ingest-task"

  name_prefix = local.name_prefix
  region      = var.region
  account_id  = local.account_id

  image              = var.ingest_image
  execution_role_arn = module.api.execution_role_arn

  index_bucket_arn  = module.index_store.bucket_arn
  index_bucket_name = module.index_store.bucket_name
  corpus_key        = var.corpus_key

  embed_model_id     = var.embed_model_id
  doc_limit          = var.doc_limit
  git_sha            = var.git_sha
  log_retention_days = var.log_retention_days
}
