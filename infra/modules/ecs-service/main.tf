resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.environment == "prod" ? "enabled" : "disabled"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.image
      essential = true

      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]

      # Configuration arrives as plain environment variables because none of it is secret.
      environment = [
        { name = "RAG_ENV", value = var.environment },
        { name = "RAG_AWS_REGION", value = var.region },
        { name = "RAG_INDEX_BUCKET", value = var.index_bucket_name },
        # The service resolves the live index from this parameter at startup, so a promotion or a
        # rollback is a parameter write plus a restart - the task definition never changes.
        { name = "RAG_ACTIVE_INDEX_PARAMETER", value = var.active_index_parameter_name },
        { name = "RAG_INDEX_VERSION", value = var.active_index_version },
        { name = "RAG_EMBED_MODEL_ID", value = var.embed_model_id },
        { name = "RAG_TEXT_MODEL_ID", value = var.text_model_id },
        { name = "RAG_MAX_OUTPUT_TOKENS", value = tostring(var.max_output_tokens) },
        { name = "RAG_RELEASE_VERSION", value = var.release_version },
        { name = "RAG_GIT_SHA", value = var.git_sha },
        { name = "RAG_DOCS_SERVERS", value = var.docs_servers },
      ]

      # Resolved by the ECS agent at task start, so the value never appears in the task definition
      # or in `describe-task-definition` output - only the ARN does.
      secrets = var.container_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }

      readonlyRootFilesystem = false # the index is downloaded to local disk at startup
      user                   = "10001:10001"
    }
  ])
}

resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Public subnets with no NAT, so tasks need a public IP to reach ECR and Bedrock. Inbound is
  # still closed: the task security group only accepts the load balancer.
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.tasks_security_group_id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "api"
    container_port   = var.container_port

    # What makes the shift possible: ECS needs the second target group and the rule it may
    # rewrite. Supplying them is the whole difference between a rolling update and a canary.
    dynamic "advanced_configuration" {
      for_each = var.deployment_strategy == "BLUE_GREEN" ? [1] : []

      content {
        alternate_target_group_arn = aws_lb_target_group.green.arn
        production_listener_rule   = aws_lb_listener_rule.production.arn
        test_listener_rule         = aws_lb_listener_rule.test[0].arn
        role_arn                   = aws_iam_role.blue_green[0].arn
      }
    }
  }

  # ECS drives both strategies natively. CodeDeploy is deliberately not used: it is a second
  # control plane to reason about, and this account cannot subscribe to it at all.
  deployment_controller {
    type = "ECS"
  }

  deployment_configuration {
    strategy             = var.deployment_strategy
    bake_time_in_minutes = var.deployment_strategy == "BLUE_GREEN" ? tostring(var.bake_time_minutes) : null

    # 10% of real traffic, held long enough for the alarms below to gather evidence before the
    # blast radius widens.
    dynamic "canary_configuration" {
      for_each = var.deployment_strategy == "BLUE_GREEN" ? [1] : []

      content {
        canary_percent              = var.canary_percent
        canary_bake_time_in_minutes = tostring(var.canary_bake_time_minutes)
      }
    }
  }

  # The one that matters: an alarm tripping mid-canary reverses the shift without a human.
  dynamic "alarms" {
    for_each = var.deployment_strategy == "BLUE_GREEN" ? [1] : []

    content {
      alarm_names = [
        aws_cloudwatch_metric_alarm.target_5xx[0].alarm_name,
        aws_cloudwatch_metric_alarm.latency_p95[0].alarm_name,
        aws_cloudwatch_metric_alarm.latency_p99[0].alarm_name,
      ]
      enable   = true
      rollback = true
    }
  }

  # The rolling rollback story: a task set that never reaches a healthy state is abandoned and the
  # previous definition restored, with no human and no pipeline step involved. A canary needs the
  # alarms above instead, because its failure mode is a task that starts healthy and serves badly.
  dynamic "deployment_circuit_breaker" {
    for_each = var.deployment_strategy == "ROLLING" ? [1] : []

    content {
      enable   = true
      rollback = true
    }
  }

  health_check_grace_period_seconds = 60
  propagate_tags                    = "SERVICE"

  # Terraform owns the task definition, which is what makes a release a plan rather than an
  # out-of-band API call. ECS shifts traffic by rewriting the listener rule, not this block, so
  # only the rule needs to be left alone.
  lifecycle {
    ignore_changes = [desired_count]
  }
}
