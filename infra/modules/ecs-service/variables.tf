variable "name_prefix" {
  description = "Resource name prefix, e.g. rag-dev."
  type        = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

# --- networking -------------------------------------------------------------

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "tasks_security_group_id" {
  type = string
}

# --- workload ---------------------------------------------------------------

variable "image" {
  description = "Fully qualified image reference. Deploys pass a digest, not a tag."
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "cpu" {
  description = "Fargate CPU units. 256 = 0.25 vCPU, the smallest billable size."
  type        = number
  default     = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  description = "Task count. Non-prod can sit at 0 when idle; prod needs at least 2 for blue/green."
  type        = number
  default     = 1
}

variable "release_version" {
  description = "Surfaced by /version so a smoke test can prove which release is serving."
  type        = string
  default     = "0.0.0-dev"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

# --- deployment strategy ----------------------------------------------------

variable "deployment_controller" {
  description = <<-EOT
    ECS  = rolling update with the deployment circuit breaker (non-prod).
    CODE_DEPLOY = blue/green with canary traffic shifting (prod).
    This is the single switch that separates the two strategies; everything else is identical,
    which is what makes non-prod a genuine rehearsal for prod.
  EOT
  type        = string
  default     = "ECS"

  validation {
    condition     = contains(["ECS", "CODE_DEPLOY"], var.deployment_controller)
    error_message = "deployment_controller must be ECS or CODE_DEPLOY."
  }
}

# --- model and index access -------------------------------------------------

variable "index_bucket_arn" {
  type = string
}

variable "index_bucket_name" {
  type = string
}

variable "active_index_parameter_arn" {
  type = string
}

variable "active_index_parameter_name" {
  description = "Read by the service at startup to discover which index is live."
  type        = string
}

variable "active_index_version" {
  description = "Injected into the task definition; a promotion is a new task definition revision."
  type        = string
  default     = "none"
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "text_model_id" {
  description = "Cross-region inference profile id. The bare foundation-model id is not invokable."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "max_output_tokens" {
  description = "Caps the cost of a single runaway request, not just its latency."
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Indefinite retention is a silent recurring cost."
  type        = number
  default     = 14
}
