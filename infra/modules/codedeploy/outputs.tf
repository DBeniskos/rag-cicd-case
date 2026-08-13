output "application_name" {
  description = "Passed to `aws deploy create-deployment` by the deploy pipeline."
  value       = aws_codedeploy_app.this.name
}

output "deployment_group_name" {
  value = aws_codedeploy_deployment_group.this.deployment_group_name
}

output "alarm_names" {
  description = "The alarms that stop and reverse a canary."
  value = [
    aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.latency_p95.alarm_name,
    aws_cloudwatch_metric_alarm.latency_p99.alarm_name,
  ]
}
