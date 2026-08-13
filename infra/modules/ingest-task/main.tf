# The ingestion job runs as a one-off ECS task rather than inside the pipeline runner.
#
# Two reasons: it gets its own IAM role, so the only identity that can *write* an index is the one
# that builds it; and a long embed run is not bounded by a CI job's lifetime or egress. The task
# definition is provisioned here; the pipeline invokes it with RunTask.

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/ecs/${var.name_prefix}-ingest"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "ingest" {
  family                   = "${var.name_prefix}-ingest"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # Embedding is IO-bound on Bedrock rather than CPU-bound, so the smallest size is enough; the
  # job's duration is dominated by waiting for the model.
  cpu                = var.cpu
  memory             = var.memory
  execution_role_arn = var.execution_role_arn
  task_role_arn      = aws_iam_role.ingest.arn

  container_definitions = jsonencode([
    {
      name      = "ingest"
      image     = var.image
      essential = true

      environment = [
        { name = "RAG_AWS_REGION", value = var.region },
        { name = "RAG_INDEX_BUCKET", value = var.index_bucket_name },
        { name = "RAG_CORPUS_KEY", value = var.corpus_key },
        { name = "RAG_EMBED_MODEL_ID", value = var.embed_model_id },
        { name = "RAG_EMBED_DIMENSIONS", value = tostring(var.embed_dimensions) },
        { name = "RAG_DOC_LIMIT", value = tostring(var.doc_limit) },
        { name = "RAG_GIT_SHA", value = var.git_sha },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ingest.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ingest"
        }
      }

      user = "10001:10001"
    }
  ])
}
