output "bucket_name" {
  value = aws_s3_bucket.index.id
}

output "bucket_arn" {
  value = aws_s3_bucket.index.arn
}

output "active_index_parameter_name" {
  description = "Written by the promotion pipeline; read by the task definition."
  value       = aws_ssm_parameter.active_index_version.name
}

output "active_index_parameter_arn" {
  value = aws_ssm_parameter.active_index_version.arn
}
