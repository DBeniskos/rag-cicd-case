variable "project" {
  description = "Prefix for every resource name in the solution."
  type        = string
  default     = "rag"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,15}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, 2-16 characters."
  }
}

variable "region" {
  description = "Region hosting the state bucket. Must match the region the stacks deploy into."
  type        = string
  default     = "us-east-1"
}

variable "budget_limit_usd" {
  description = "Monthly cost budget in USD. Alerts only - AWS has no hard spend cap."
  type        = string
  default     = "20"
}

variable "budget_alert_thresholds" {
  description = "Percentages of the budget at which an actual-spend alert fires."
  type        = list(number)
  default     = [50, 80, 100]
}

variable "budget_notification_email" {
  description = "Address that receives budget alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be a valid email address."
  }
}
