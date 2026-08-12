# Copied into GitHub as repository variables — the workflows reference roles by ARN, so nothing
# about the account is hard-coded in committed YAML.

output "ci_role_arn" {
  description = "Assumed by ci.yml. Read and plan only."
  value       = aws_iam_role.ci.arn
}

output "release_role_arn" {
  description = "Assumed by release.yml. ECR push only."
  value       = aws_iam_role.release.arn
}

output "deployment_role_arn" {
  description = "Assumed by deploy.yml and index.yml. Applies infrastructure and shifts traffic."
  value       = aws_iam_role.deployment.arn
}

output "ecr_repository_urls" {
  description = "Registry URL per component."
  value       = { for name, repo in aws_ecr_repository.component : name => repo.repository_url }
}

output "ecr_registry" {
  description = "Registry host, used by docker login in the release pipeline."
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
