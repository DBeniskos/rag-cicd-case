# Blue/green with canary traffic shifting.
#
# The reason this exists rather than a rolling update: a GenAI API's worst failure is "healthy,
# fast, and confidently wrong". A rolling update with health checks cannot see that, because the
# container is genuinely healthy. Shifting a small slice of real traffic first, watching real
# error and latency signals, and keeping the old task set alive to fall back to, is the only
# mechanism here that can catch a bad release *after* it passes every pre-deploy check.

resource "aws_codedeploy_app" "this" {
  name             = "${var.name_prefix}-api"
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name              = aws_codedeploy_app.this.name
  deployment_group_name = "${var.name_prefix}-api"
  service_role_arn      = aws_iam_role.codedeploy.arn

  # 10% for five minutes, then the remainder. Long enough for the alarms above to gather two
  # evaluation periods of real traffic before the blast radius widens.
  deployment_config_name = var.deployment_config_name

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  auto_rollback_configuration {
    enabled = true
    events = [
      "DEPLOYMENT_FAILURE",
      # The one that matters: an alarm tripping mid-canary reverses the shift without a human.
      "DEPLOYMENT_STOP_ON_ALARM",
    ]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.latency_p95.alarm_name,
      aws_cloudwatch_metric_alarm.latency_p99.alarm_name,
    ]
    # If CloudWatch itself cannot be reached, continue rather than block all releases on a
    # monitoring outage. The trade-off is explicit: availability of the pipeline over certainty.
    ignore_poll_alarm_failure = true
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # Traffic shifting starts as soon as the green task set is healthy. A manual approval step
      # already ran in the pipeline; a second wait here would only add dead time.
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      # The window in which a rollback is instant, because the old task set is still running.
      # Shorter is cheaper; longer is safer. Five minutes covers the time a human needs to notice
      # something the alarms did not.
      termination_wait_time_in_minutes = var.blue_termination_wait_minutes
    }
  }

  ecs_service {
    cluster_name = var.cluster_name
    service_name = var.service_name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.production_listener_arn]
      }

      # Validation happens here before any real user is exposed to the new task set.
      test_traffic_route {
        listener_arns = [var.test_listener_arn]
      }

      target_group {
        name = var.blue_target_group_name
      }

      target_group {
        name = var.green_target_group_name
      }
    }
  }
}
