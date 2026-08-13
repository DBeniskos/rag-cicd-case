# Alarms that gate a deployment.
#
# These are deliberately separate from general dashboards and paging: their job is to answer one
# question during a canary — "is the new task set worse than the old one?" — and to answer it
# fast enough to matter. Evaluation periods are therefore short and thresholds are tight.

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name_prefix}-target-5xx"
  alarm_description   = "Application errors from the API. Trips a canary rollback."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_count_threshold
  period              = 60
  evaluation_periods  = 1
  # A canary carries a fraction of traffic, so absent data means "no errors seen", not "unknown".
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95"
  alarm_description   = "p95 response time. A slow model response is a user-visible outage."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_threshold_seconds
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}

# p95 alone hides the case where the model answers quickly but wrongly, and where a handful of
# requests hang for the full Bedrock timeout. This catches the long tail that averages conceal.
resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  alarm_name          = "${var.name_prefix}-latency-p99"
  alarm_description   = "p99 response time. Catches a stalled Bedrock call the p95 would absorb."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p99_threshold_seconds
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }
}
