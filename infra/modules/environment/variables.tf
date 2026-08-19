variable "project" {
  type    = string
  default = "rag"
}

variable "environment" {
  description = "dev or prod."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
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

variable "test_ingress_cidrs" {
  description = "Sources allowed to reach the test listener. The deployment gate calls it from Lambda, whose egress address cannot be pinned, so a gated environment has to allow the internet and rely on the API key /ask already requires."
  type        = list(string)
  default     = []
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

variable "deployment_strategy" {
  description = "ROLLING (in-place, circuit breaker and alarms) or BLUE_GREEN (second task set, gated, then shifted)."
  type        = string
  default     = "ROLLING"
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
  description = <<-EOT
    Cross-region inference profile id for generation.

    Nova Lite is the default because Anthropic models on Bedrock additionally require a per-account
    use case form that cannot be submitted from Terraform. Switching to
    "us.anthropic.claude-haiku-4-5-20251001-v1:0" is supported and requires no code change; the IAM
    policy derives the foundation-model ARNs from this value.
  EOT
  type        = string
  default     = "us.amazon.nova-lite-v1:0"
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

variable "docs_servers" {
  description = "Targets offered in the docs Servers dropdown, as comma-separated 'label=url' pairs. Lets one console exercise every environment."
  type        = string
  default     = ""
}

variable "bake_time_minutes" {
  description = "How long an instant rollback stays possible after a successful shift."
  type        = number
  default     = 5
}

variable "alert_email" {
  description = "Address subscribed to the environment's alarm topic. Empty means the topic exists but has no subscriber, which is still better than alarms with nowhere to publish."
  type        = string
  default     = ""
}

variable "gate_timeout_seconds" {
  description = "Budget for the whole golden set inside the deployment gate."
  type        = number
  default     = 300
}

variable "error_count_threshold" {
  description = "5xx responses in one minute that fail a deployment."
  type        = number
  default     = 5
}

variable "latency_p95_threshold_seconds" {
  description = "Deployment latency budget. Bedrock generation dominates it."
  type        = number
  default     = 12
}

variable "latency_p99_threshold_seconds" {
  description = "Long-tail budget. Catches a stalled Bedrock call the p95 absorbs."
  type        = number
  default     = 20
}
