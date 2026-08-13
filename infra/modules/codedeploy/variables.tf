variable "name_prefix" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "alb_arn_suffix" {
  description = "Required by the CloudWatch alarms that gate the canary."
  type        = string
}

variable "production_listener_arn" {
  type = string
}

variable "test_listener_arn" {
  description = "Validated before any production traffic reaches the new task set."
  type        = string
}

variable "blue_target_group_name" {
  type = string
}

variable "green_target_group_name" {
  type = string
}

variable "deployment_config_name" {
  description = "Traffic shifting shape. Canary exposes a slice first; Linear ramps evenly."
  type        = string
  default     = "CodeDeployDefault.ECSCanary10Percent5Minutes"
}

variable "blue_termination_wait_minutes" {
  description = "How long the previous task set stays alive, and therefore how long an instant rollback remains possible."
  type        = number
  default     = 5
}

variable "error_count_threshold" {
  description = "5xx responses per minute that constitute a failed canary."
  type        = number
  default     = 5
}

variable "latency_p95_threshold_seconds" {
  description = "p95 budget. Bedrock generation dominates this, so it is well above a plain API."
  type        = number
  default     = 4
}

variable "latency_p99_threshold_seconds" {
  description = "p99 budget. Catches stalled model calls the p95 would absorb."
  type        = number
  default     = 10
}
