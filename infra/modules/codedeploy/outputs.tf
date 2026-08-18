output "application_name" {
  description = "Passed to `aws deploy create-deployment` by the deploy pipeline."
  value       = aws_codedeploy_app.this.name
}

output "deployment_group_name" {
  value = aws_codedeploy_deployment_group.this.deployment_group_name
}
