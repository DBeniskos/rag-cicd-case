# Alarms that fail a deployment.
#
# Their job is to answer one question during a release — "is the new task set worse than the old
# one?" — and to answer it fast enough to matter. Evaluation periods are therefore short and
# thresholds tight.
#
# One alarm per target group, not one per load balancer. Scoped to the ALB, a new task set is
# averaged against the traffic still on the old version, and a p95 cannot see a task set failing
# every request because the 95th percentile sits inside the healthy majority. Which group holds
# the new release alternates every blue/green release, so both are alarmed and both are
# registered. A rolling environment only ever uses blue, so alarming green there would create an
# alarm that can never have data.
locals {
  alarm_target_groups = local.traffic_shifting ? {
    blue  = aws_lb_target_group.blue.arn_suffix
    green = aws_lb_target_group.green.arn_suffix
    } : {
    blue = aws_lb_target_group.blue.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each = local.alarm_target_groups

  alarm_name          = "${var.name_prefix}-target-5xx-${each.key}"
  alarm_description   = "Application errors from the ${each.key} task set. Fails the deployment and rolls it back."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_count_threshold
  period              = 60
  evaluation_periods  = 1
  # A new task set carries a fraction of traffic, so absent data means "no errors seen", not
  # "unknown". The gate, not these alarms, is what proves the release is actually good.
  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  for_each = local.alarm_target_groups

  alarm_name          = "${var.name_prefix}-latency-p95-${each.key}"
  alarm_description   = "p95 response time of the ${each.key} task set. A slow model response is a user-visible outage."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p95_threshold_seconds
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.value
  }
}

# p95 alone absorbs the case where a handful of requests hang for the full Bedrock timeout. This
# catches the long tail that percentile averaging conceals.
resource "aws_cloudwatch_metric_alarm" "latency_p99" {
  for_each = local.alarm_target_groups

  alarm_name          = "${var.name_prefix}-latency-p99-${each.key}"
  alarm_description   = "p99 response time of the ${each.key} task set. Catches a stalled Bedrock call the p95 would absorb."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.latency_p99_threshold_seconds
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.value
  }
}
