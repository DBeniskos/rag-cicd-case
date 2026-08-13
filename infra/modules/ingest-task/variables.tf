variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "image" {
  description = "Ingest image reference; the pipeline passes a digest."
  type        = string
}

variable "execution_role_arn" {
  description = "Reused from the API service — pulling an image and writing logs is the same job."
  type        = string
}

variable "index_bucket_arn" {
  type = string
}

variable "index_bucket_name" {
  type = string
}

variable "corpus_key" {
  type    = string
  default = "raw/movie_plots.csv"
}

variable "embed_model_id" {
  type    = string
  default = "amazon.titan-embed-text-v2:0"
}

variable "embed_dimensions" {
  type    = number
  default = 1024
}

variable "doc_limit" {
  type    = number
  default = 400
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "log_retention_days" {
  type    = number
  default = 14
}
