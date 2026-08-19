variable "name_prefix" {
  description = "Resource name prefix, e.g. rag-prod."
  type        = string
}

variable "environment" {
  description = "Selects the threshold set the gate enforces."
  type        = string
}

variable "account_id" {
  type = string
}

variable "alb_name" {
  description = "Load balancer whose test listener the gate probes. Resolved to a DNS name at invocation, not at plan time: taking it as an input would make the service depend on the gate and the gate depend on the service."
  type        = string
}

variable "test_port" {
  description = "Test listener port the new task set answers on while production traffic is still on the old one."
  type        = number
  default     = 8080
}

variable "api_key_secret_arn" {
  description = "Secret holding the x-api-key value /ask requires."
  type        = string
}

variable "case_timeout_seconds" {
  description = "Per-question timeout. The gate must finish well inside the Lambda timeout."
  type        = number
  default     = 25
}

variable "timeout_seconds" {
  description = "Lambda timeout. Must exceed the whole golden set run, or the gate fails releases it never judged."
  type        = number
  default     = 300
}

variable "log_retention_days" {
  type    = number
  default = 30
}
