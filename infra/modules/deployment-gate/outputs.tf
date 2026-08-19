output "function_arn" {
  description = "Passed to the service as the lifecycle hook target."
  value       = aws_lambda_function.gate.arn
}

output "function_name" {
  value = aws_lambda_function.gate.function_name
}

output "invoke_role_arn" {
  description = "The role ECS assumes to call the gate."
  value       = aws_iam_role.invoke.arn
}

output "log_group_name" {
  description = "Where the gate's verdict and failing cases are recorded."
  value       = aws_cloudwatch_log_group.gate.name
}
