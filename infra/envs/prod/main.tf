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
    # Packages the deployment gate's Lambda bundle.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
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

variable "test_ingress_cidrs" {
  description = <<-EOT
    Who may reach the test listener on :8080. The deployment gate calls it from Lambda, whose
    egress address is not fixed and cannot be allowlisted, so this is open by default. What bounds
    the exposure is the API key: :8080 serves the same application as :80 and /ask rejects an
    unauthenticated caller on both. Only /healthz is readable, and only for the minutes a
    deployment is in flight. Narrow it if the gate ever moves inside the VPC.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "alert_email" {
  description = "Optional subscriber for the alarm topic. Left empty by default so an apply does not send mail to an address nobody asked about."
  type        = string
  default     = ""
  sensitive   = true
}

# Prod differs from dev only in retention, task count and deployment strategy: same modules, same
# inputs otherwise. The index store keeps force_destroy off, so a stray destroy cannot take the
# corpus with it.
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
  # Blue/green, not canary. A canary trades blast radius for observation time, and is worth it
  # only when correctness can be judged solely from production traffic. Here it can be judged
  # before any: the golden set runs against the new task set on the test listener and vetoes the
  # shift, so a bad release reaches nobody rather than a tenth of everybody.
  deployment_strategy = "BLUE_GREEN"
  test_ingress_cidrs  = var.test_ingress_cidrs
  docs_servers        = var.docs_servers
  alert_email         = var.alert_email

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

output "gate_log_group_name" {
  value = module.environment.gate_log_group_name
}

output "alert_topic_arn" {
  value = module.environment.alert_topic_arn
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
