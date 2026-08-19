# The gap the alarms leave.
#
# Alarms only fire on metrics, so they cover a task set that serves badly. They say nothing when a
# deployment is reversed for any other reason — the gate voting FAILED, the circuit breaker giving
# up on a task that never starts — because in those cases no traffic was ever served and no metric
# ever moved. Those are the events worth waking someone for, and until this rule existed they were
# visible only to whoever happened to read the pipeline log.
#
# ECS already announces them on the default event bus. Nothing was listening.

resource "aws_cloudwatch_event_rule" "deployment_failed" {
  count = var.alarm_topic_arn == "" ? 0 : 1

  name        = "${var.name_prefix}-deployment-failed"
  description = "ECS abandoned or reversed a deployment of ${var.name_prefix}-api."

  # Scoped to this service: the account's other services have their own topics.
  event_pattern = jsonencode({
    source        = ["aws.ecs"]
    "detail-type" = ["ECS Deployment State Change"]
    resources     = [aws_ecs_service.api.arn]
    detail = {
      eventName = ["SERVICE_DEPLOYMENT_FAILED"]
    }
  })
}

resource "aws_cloudwatch_event_target" "deployment_failed" {
  count = var.alarm_topic_arn == "" ? 0 : 1

  rule      = aws_cloudwatch_event_rule.deployment_failed[0].name
  target_id = "alerts"
  arn       = var.alarm_topic_arn

  # A raw event document in an inbox is unreadable at 2am. Three facts matter: which service, why,
  # and when. Every path used here is present on this event type, so the transform cannot silently
  # drop the notification.
  input_transformer {
    input_paths = {
      service = "$.resources[0]"
      reason  = "$.detail.reason"
      at      = "$.detail.updatedAt"
    }
    input_template = "\"ECS reversed a deployment. service=<service> reason=<reason> at=<at>\""
  }
}
