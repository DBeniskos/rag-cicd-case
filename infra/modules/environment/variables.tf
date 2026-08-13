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

variable "ingest_image" {
  description = <<-EOT
    Ingest image reference. Deliberately has no default and no fallback to the API image: an
    earlier version fell back, so the one-off ingestion task started a web server and ran forever
    instead of failing. A wrong value must break the plan, not the runtime.
  EOT
  type        = string

  validation {
    condition     = can(regex("rag-ingest[@:]", var.ingest_image))
    error_message = "ingest_image must reference the rag-ingest repository, not another image."
  }
}

variable "corpus_key" {
  description = "S3 key of the source corpus, under the raw/ prefix."
  type        = string
  default     = "raw/movie_plots.csv"
}

variable "doc_limit" {
  description = "Documents to ingest. The corpus is not the point; exercising the pipeline is."
  type        = number
  default     = 400
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
  description = "Cross-region inference profile id for generation."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
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
