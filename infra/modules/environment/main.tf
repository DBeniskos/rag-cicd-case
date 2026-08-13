# One environment, assembled from the reusable modules.
#
# This layer exists so dev, stage and prod are the *same* code with different inputs. If each
# environment wired the modules itself, they would drift, and non-prod would stop being a
# rehearsal for prod — which is the only reason non-prod is worth paying for.

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
}

module "network" {
  source = "../network"

  name_prefix    = local.name_prefix
  cidr_block     = var.cidr_block
  container_port = var.container_port
  ingress_cidrs  = var.ingress_cidrs
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

  deployment_controller = var.deployment_controller

  index_bucket_arn           = module.index_store.bucket_arn
  index_bucket_name          = module.index_store.bucket_name
  active_index_parameter_arn = module.index_store.active_index_parameter_arn
  active_index_version       = var.active_index_version

  embed_model_id    = var.embed_model_id
  text_model_id     = var.text_model_id
  max_output_tokens = var.max_output_tokens

  log_retention_days = var.log_retention_days
}

# The ingestion job exists in every environment, because an index has to be built where it will be
# served: the same corpus embedded by the same model, written to that environment's own bucket.
module "ingest" {
  source = "../ingest-task"

  name_prefix = local.name_prefix
  region      = var.region
  account_id  = local.account_id

  # Falls back to the API image so the first apply of a new environment succeeds before an ingest
  # image has ever been released. index.yml overrides it with the real digest.
  image              = var.ingest_image != "" ? var.ingest_image : var.image
  execution_role_arn = module.api.execution_role_arn

  index_bucket_arn  = module.index_store.bucket_arn
  index_bucket_name = module.index_store.bucket_name
  corpus_key        = var.corpus_key

  embed_model_id     = var.embed_model_id
  doc_limit          = var.doc_limit
  git_sha            = var.git_sha
  log_retention_days = var.log_retention_days
}

# Only blue/green environments get a CodeDeploy application. Dev relies on the ECS deployment
# circuit breaker instead, which is a different rollback mechanism rather than a lesser one:
# it reverses a task set that never becomes healthy, where CodeDeploy reverses one that is
# healthy but performing worse.
module "codedeploy" {
  count  = var.deployment_controller == "CODE_DEPLOY" ? 1 : 0
  source = "../codedeploy"

  name_prefix  = local.name_prefix
  cluster_name = module.api.cluster_name
  service_name = module.api.service_name

  alb_arn_suffix          = module.api.alb_arn_suffix
  production_listener_arn = module.api.production_listener_arn
  test_listener_arn       = module.api.test_listener_arn
  blue_target_group_name  = module.api.blue_target_group_name
  green_target_group_name = module.api.green_target_group_name

  deployment_config_name        = var.deployment_config_name
  blue_termination_wait_minutes = var.blue_termination_wait_minutes
  latency_p95_threshold_seconds = var.latency_p95_threshold_seconds
}
