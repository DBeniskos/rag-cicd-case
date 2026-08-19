# Two target groups exist in every environment, not just prod.
#
# A staged rollout needs somewhere to put the new task set, and ECS swaps which group the
# production listener rule points at. Creating both everywhere keeps the module identical across
# environments — non-prod simply never exercises the second one.

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.subnet_ids
  security_groups    = [var.alb_security_group_id]

  # An ALB rather than the NLB used previously: L7 gives per-request 5xx and latency metrics, and
  # weighted target groups make a traffic shift possible. Both are prerequisites for gating a
  # release on response quality rather than on whether the port answers.
  idle_timeout               = 65
  drop_invalid_header_fields = true
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "blue" {
  name        = "${var.name_prefix}-blue"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Fargate replaces tasks rather than restarting them, so draining only needs to outlast
  # in-flight requests. The default 300s makes every rollback five minutes slower than necessary.
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${var.name_prefix}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "production" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # The rule below carries every request. This only answers what matches nothing, which on a
  # single-service listener means a misrouted request rather than a user.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no route"
      status_code  = "404"
    }
  }
}

# ECS rewrites this rule's forward action to move traffic between blue and green, so Terraform
# must stop asserting it or the next apply would undo a completed shift.
resource "aws_lb_listener_rule" "production" {
  listener_arn = aws_lb_listener.production.arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}

# The test listener is how a new task set is reachable before any production traffic reaches it.
resource "aws_lb_listener" "test" {
  count = local.traffic_shifting ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no route"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "test" {
  count = local.traffic_shifting ? 1 : 0

  listener_arn = aws_lb_listener.test[0].arn
  priority     = 1

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }

  lifecycle {
    ignore_changes = [action]
  }
}
