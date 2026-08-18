# Consumed by scripts/bootstrap.sh to write the backend config every other layer uses,
# so the bucket name is never copied by hand into a second place.

output "state_bucket" {
  description = "S3 bucket holding Terraform state for the platform and environment layers."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}

output "account_id" {
  description = "Account this solution is deployed into."
  value       = data.aws_caller_identity.current.account_id
}

output "budget_name" {
  description = "Monthly cost budget guarding the account."
  value       = aws_budgets_budget.monthly.name
}
