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

variable "deployment_strategy" {
  description = <<-EOT
    ROLLING    = in-place replacement guarded by the deployment circuit breaker (dev).
    BLUE_GREEN = second task set, canary traffic shift, alarm-triggered rollback (prod).
    This is the single switch that separates the two strategies; everything else is identical,
    which is what makes dev a genuine rehearsal for prod.
  EOT
  type        = string
  default     = "ROLLING"

  validation {
    condition     = contains(["ROLLING", "BLUE_GREEN"], var.deployment_strategy)
    error_message = "deployment_strategy must be ROLLING or BLUE_GREEN."
  }
}

variable "canary_percent" {
  description = "Share of traffic the green task set receives before the bake period."
  type        = number
  default     = 10
}

variable "canary_bake_time_minutes" {
  description = "How long the canary holds at canary_percent while the alarms gather evidence."
  type        = number
  default     = 5
}

variable "bake_time_minutes" {
  description = "How long the previous task set is kept after a full shift, and therefore how long an instant rollback stays possible."
  type        = number
  default     = 5
}

variable "error_count_threshold" {
  description = "5xx responses in one minute that abort a canary."
  type        = number
  default     = 5
}

variable "latency_p95_threshold_seconds" {
  type    = number
  default = 12
}

variable "latency_p99_threshold_seconds" {
  type    = number
  default = 20
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
  default     = "us.amazon.nova-lite-v1:0"
}

variable "container_secrets" {
  description = "Secrets Manager values injected by the ECS agent as environment variables."
  type = list(object({
    name      = string
    valueFrom = string
  }))
  default = []
}

variable "secret_arns" {
  description = "ARNs the execution role may read. Kept separate so the policy is not derived from a computed list."
  type        = list(string)
  default     = []
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
