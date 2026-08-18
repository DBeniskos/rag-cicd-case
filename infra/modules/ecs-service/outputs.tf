output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.api.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.api.family
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "alb_dns_name" {
  description = "Base URL for smoke tests and the eval harness."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "Required by CloudWatch alarms on ALB metrics."
  value       = aws_lb.this.arn_suffix
}

output "blue_target_group_name" {
  value = aws_lb_target_group.blue.name
}

output "green_target_group_name" {
  value = aws_lb_target_group.green.name
}

output "production_listener_arn" {
  value = aws_lb_listener.production.arn
}

output "test_listener_arn" {
  description = "Only created for blue/green environments."
  value       = try(aws_lb_listener.test[0].arn, null)
}

output "rollback_alarm_names" {
  description = "The alarms that reverse a canary. Empty where the strategy is rolling."
  value = local.traffic_shifting ? concat(
    [for a in aws_cloudwatch_metric_alarm.target_5xx : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.latency_p95 : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.latency_p99 : a.alarm_name],
  ) : []
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.api.name
}
