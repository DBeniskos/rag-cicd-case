variable "project" {
  type    = string
  default = "rag"
}

variable "environment" {
  description = "dev, stage or prod."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cidr_block" {
  description = "Distinct per environment so peering remains possible without renumbering."
  type        = string
}

variable "ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "image" {
  description = "Image reference. deploy.yml passes a digest so the promoted bytes are exact."
  type        = string
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "deployment_controller" {
  description = "ECS (rolling + circuit breaker) or CODE_DEPLOY (blue/green canary)."
  type        = string
  default     = "ECS"
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

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "text_model_id" {
  type    = string
  default = "anthropic.claude-3-5-haiku-20241022-v1:0"
}

variable "max_output_tokens" {
  type    = number
  default = 512
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "index_retention_days" {
  type    = number
  default = 30
}

variable "deployment_config_name" {
  description = "CodeDeploy traffic-shifting shape. Ignored unless blue/green."
  type        = string
  default     = "CodeDeployDefault.ECSCanary10Percent5Minutes"
}

variable "blue_termination_wait_minutes" {
  description = "How long an instant rollback stays possible after a successful shift."
  type        = number
  default     = 5
}

variable "latency_p95_threshold_seconds" {
  description = "Canary latency budget. Bedrock generation dominates it."
  type        = number
  default     = 4
}
