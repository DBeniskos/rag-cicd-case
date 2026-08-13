output "task_definition_family" {
  description = "Passed to `aws ecs run-task` by index.yml."
  value       = aws_ecs_task_definition.ingest.family
}

output "task_role_arn" {
  value = aws_iam_role.ingest.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.ingest.name
}
