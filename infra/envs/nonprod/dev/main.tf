terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key = "envs/nonprod/dev/terraform.tfstate"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "rag"
      Environment = "dev"
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
  description = "Set by deploy.yml to the digest being promoted."
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

# Dev: rolling updates with the circuit breaker, one task, short log retention. Fast and cheap,
# and the first place a bad release is caught.
module "environment" {
  source = "../../../modules/environment"

  environment = "dev"
  region      = var.region
  cidr_block  = "10.20.0.0/16"

  image                = var.image
  release_version      = var.release_version
  git_sha              = var.git_sha
  active_index_version = var.active_index_version

  desired_count         = 1
  deployment_controller = "ECS"

  log_retention_days   = 7
  index_retention_days = 14
}

output "api_url" {
  value = module.environment.api_url
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

output "deployment_controller" {
  value = module.environment.deployment_controller
}

output "codedeploy_application_name" {
  value = module.environment.codedeploy_application_name
}

output "codedeploy_deployment_group_name" {
  value = module.environment.codedeploy_deployment_group_name
}
