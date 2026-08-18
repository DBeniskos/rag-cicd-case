variable "project" {
  description = "Prefix for every resource name in the solution."
  type        = string
  default     = "rag"
}

variable "region" {
  description = "Region for the registry and pipeline roles."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the pipeline roles, as owner/repo."
  type        = string

  validation {
    # The trust policy is only as good as this string: a typo that widens it (say, a bare owner)
    # would let any repository in that account assume a deploy role.
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be exactly owner/repo, e.g. octocat/rag-cicd-case."
  }
}

# GitHub now issues immutable subject claims that embed numeric ids:
#   repo:owner@156813366/repo@1332120918:ref:refs/heads/main
# Supplying the ids pins trust to the identity rather than the name, so deleting and recreating a
# repository with the same name no longer satisfies the policy. Discovered automatically by
# scripts/platform.sh.
variable "github_owner_id" {
  description = "Numeric GitHub owner id. Empty falls back to the older name-based subject claim."
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "Numeric GitHub repository id. Empty falls back to the older name-based claim."
  type        = string
  default     = ""
}

variable "protected_prod_ref" {
  description = "Git ref permitted to deploy to prod."
  type        = string
  default     = "refs/heads/main"
}

variable "components" {
  description = "Independently released container images, each getting its own ECR repository."
  type        = list(string)
  default     = ["api", "ingest"]
}

variable "image_retention_count" {
  description = "Tagged images kept per repository before the oldest are expired."
  type        = number
  default     = 15
}
