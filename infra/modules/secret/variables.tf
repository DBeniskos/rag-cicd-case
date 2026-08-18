variable "name_prefix" {
  description = "Resource name prefix, e.g. rag-dev."
  type        = string
}

variable "secret_envvar_name" {
  description = "Environment variable the container reads this secret from, e.g. RAG_API_KEY."
  type        = string

  validation {
    condition     = can(regex("^[A-Z][A-Z0-9_]*$", var.secret_envvar_name))
    error_message = "secret_envvar_name must be UPPER_SNAKE_CASE."
  }
}

variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "allowed_roles_arn" {
  description = "Roles permitted to read the secret. Empty means no resource policy is attached."
  type        = list(string)
  default     = []
}

variable "recovery_window_days" {
  description = "0 deletes immediately; 7-30 keeps a recovery window."
  type        = number
  default     = 0

  validation {
    condition     = var.recovery_window_days == 0 || (var.recovery_window_days >= 7 && var.recovery_window_days <= 30)
    error_message = "recovery_window_days must be 0, or between 7 and 30."
  }
}

variable "value_length" {
  type    = number
  default = 48
}

variable "value_version" {
  description = "Bump to rotate. Write-only values cannot be diffed, so this is what triggers a write."
  type        = number
  default     = 1
}
