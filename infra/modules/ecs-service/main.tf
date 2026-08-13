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

      # Configuration arrives as plain environment variables because none of it is secret. Real
      # secrets would use the `secrets` block with a Secrets Manager ARN, which keeps values out
      # of the task definition and out of `describe-task-definition` output.
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
      ]

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
  }

  deployment_controller {
    type = var.deployment_controller
  }

  # The circuit breaker is the non-prod rollback story: a task set that never reaches a healthy
  # state is abandoned and the previous definition is restored automatically, with no human and no
  # pipeline step involved. Under CODE_DEPLOY this is ignored, because CodeDeploy owns rollback.
  dynamic "deployment_circuit_breaker" {
    for_each = var.deployment_controller == "ECS" ? [1] : []

    content {
      enable   = true
      rollback = true
    }
  }

  health_check_grace_period_seconds = 60
  propagate_tags                    = "SERVICE"

  # CodeDeploy owns the task definition and the live target group during a blue/green release.
  # Terraform must not fight it, or the next apply would revert a completed deployment.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }
}
