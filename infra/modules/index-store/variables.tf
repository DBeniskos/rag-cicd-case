variable "name_prefix" {
  description = "Resource name prefix, e.g. rag-dev."
  type        = string
}

variable "environment" {
  description = "Environment name; also the SSM namespace segment."
  type        = string
}

variable "account_id" {
  description = "Account id, used to keep the bucket name globally unique."
  type        = string
}

variable "initial_index_version" {
  description = "Bootstrap pointer value. 'none' means the API starts healthy but refuses /ask."
  type        = string
  default     = "none"
}

variable "index_retention_days" {
  description = "How far back an index rollback can reach. Trades storage cost against recovery."
  type        = number
  default     = 30
}

variable "force_destroy" {
  description = "Allow destroying a non-empty bucket. True in non-prod so teardown is reliable."
  type        = bool
  default     = true
}
