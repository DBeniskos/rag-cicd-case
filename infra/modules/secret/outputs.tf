output "arn" {
  description = "Secret ARN, used as valueFrom in the task definition and in the execution role policy."
  value       = aws_secretsmanager_secret.this.arn
}

output "name" {
  value = aws_secretsmanager_secret.this.name
}

output "container_secret" {
  description = "Ready-formed entry for an ECS container definition `secrets` block."
  value = {
    name      = var.secret_envvar_name
    valueFrom = aws_secretsmanager_secret.this.arn
  }
}
