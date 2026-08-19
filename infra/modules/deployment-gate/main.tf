# The quality gate, packaged as the Lambda ECS calls mid-deployment.
#
# The golden set and the harness are the same files the pipeline runs, zipped in beside the
# handler. Vendoring them keeps one definition of "good": if the gate drifted from eval/, a
# release could pass in CI and be rejected here, or worse, the reverse.

data "archive_file" "gate" {
  type        = "zip"
  output_path = "${path.module}/build/${var.name_prefix}-gate.zip"

  source {
    content  = file("${path.module}/src/handler.py")
    filename = "handler.py"
  }

  source {
    content  = file("${path.module}/../../../eval/run_eval.py")
    filename = "run_eval.py"
  }

  source {
    content  = file("${path.module}/../../../eval/golden_set.jsonl")
    filename = "golden_set.jsonl"
  }

  source {
    content  = file("${path.module}/../../../eval/thresholds.toml")
    filename = "thresholds.toml"
  }
}

resource "aws_cloudwatch_log_group" "gate" {
  name              = "/aws/lambda/${var.name_prefix}-deployment-gate"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "gate" {
  function_name = "${var.name_prefix}-deployment-gate"
  description   = "Runs the golden set against the test listener and vetoes the production traffic shift."
  role          = aws_iam_role.gate.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]

  filename         = data.archive_file.gate.output_path
  source_code_hash = data.archive_file.gate.output_base64sha256

  # Long enough for the whole golden set; a gate that times out is a gate that blocks good releases.
  timeout     = var.timeout_seconds
  memory_size = 512

  # No VPC attachment: the listener it validates is on a public load balancer, and a Lambda in
  # these subnets has no route to it without a NAT gateway.
  environment {
    variables = {
      ALB_NAME             = var.alb_name
      TEST_PORT            = tostring(var.test_port)
      RAG_ENV              = var.environment
      API_KEY_SECRET_ID    = var.api_key_secret_arn
      CASE_TIMEOUT_SECONDS = tostring(var.case_timeout_seconds)
    }
  }

  depends_on = [aws_cloudwatch_log_group.gate]
}
