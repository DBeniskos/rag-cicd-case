terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    key = "envs/prod/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "rag"
      Environment = "prod"
      Layer       = "environment"
      ManagedBy   = "terraform"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "image" {
  description = "Set by deploy.yml to the digest already proven in dev."
  type        = string
}

variable "ingest_image" {
  description = "Set by deploy.yml to the rag-ingest digest for the same release."
  type        = string
}

variable "release_version" {
  type    = string
  default = "0.0.0-dev"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

variable "active_index_version" {
  type    = string
  default = "none"
}

variable "docs_servers" {
  description = <<-EOT
    Targets in the docs Servers dropdown. Prod lists both its own listeners so one console can
    compare the live task set against the one held behind the test listener during a shift.
    Deliberately no cross-environment entries: a prod console that can call dev invites the
    mistake of reading dev's answers and believing they came from prod.
  EOT
  type        = string
  default     = "prod (live)=http://rag-prod-alb-464900636.us-east-1.elb.amazonaws.com,prod (inactive task set)=http://rag-prod-alb-464900636.us-east-1.elb.amazonaws.com:8080"
}

# Prod differs from dev only in retention, task count and deployment controller: same modules,
# same inputs otherwise. The index store keeps force_destroy off, so a stray destroy cannot take
# the corpus with it.
module "environment" {
  source = "../../modules/environment"

  environment = "prod"
  region      = var.region
  cidr_block  = "10.22.0.0/16"

  image                = var.image
  ingest_image         = var.ingest_image
  release_version      = var.release_version
  git_sha              = var.git_sha
  active_index_version = var.active_index_version

  desired_count = 2
  # CANARY rather than BLUE_GREEN: the latter shifts 100% the moment the new task set is healthy,
  # which leaves the alarms nothing to observe before the blast radius is total.
  deployment_strategy = "CANARY"
  docs_servers        = var.docs_servers

  log_retention_days   = 30
  index_retention_days = 90
}

output "api_url" {
  value = module.environment.api_url
}

# The name, never the value: callers that are allowed the key read it from Secrets Manager.
output "api_key_secret_name" {
  value = module.environment.api_key_secret_name
}

output "api_key_secret_arn" {
  value = module.environment.api_key_secret_arn
}

output "index_bucket" {
  value = module.environment.index_bucket
}

output "cluster_name" {
  value = module.environment.cluster_name
}

output "service_name" {
  value = module.environment.service_name
}

output "active_index_parameter_name" {
  value = module.environment.active_index_parameter_name
}

output "task_definition_family" {
  value = module.environment.task_definition_family
}

output "deployment_strategy" {
  value = module.environment.deployment_strategy
}

output "test_url" {
  value = module.environment.test_url
}

output "rollback_alarm_names" {
  value = module.environment.rollback_alarm_names
}

output "ingest_task_family" {
  value = module.environment.ingest_task_family
}

output "ingest_log_group_name" {
  value = module.environment.ingest_log_group_name
}

output "subnet_ids" {
  value = module.environment.subnet_ids
}

output "tasks_security_group_id" {
  value = module.environment.tasks_security_group_id
}
