output "api_url" {
  description = "Base URL used by smoke tests, the eval harness and the demo."
  value       = "http://${module.api.alb_dns_name}"
}

# The name, never the value. Callers that are allowed the key fetch it from Secrets Manager, so it
# is not carried in Terraform output, in CI logs or in a workflow artifact.
output "api_key_secret_name" {
  value = module.api_key_secret.name
}

output "api_key_secret_arn" {
  value = module.api_key_secret.arn
}

output "cluster_name" {
  value = module.api.cluster_name
}

output "service_name" {
  value = module.api.service_name
}

output "task_definition_family" {
  value = module.api.task_definition_family
}

output "index_bucket" {
  value = module.index_store.bucket_name
}

output "active_index_parameter_name" {
  value = module.index_store.active_index_parameter_name
}

output "blue_target_group_name" {
  value = module.api.blue_target_group_name
}

output "green_target_group_name" {
  value = module.api.green_target_group_name
}

output "production_listener_arn" {
  value = module.api.production_listener_arn
}

output "test_listener_arn" {
  value = module.api.test_listener_arn
}

output "alb_arn_suffix" {
  value = module.api.alb_arn_suffix
}

output "log_group_name" {
  value = module.api.log_group_name
}

output "deployment_strategy" {
  description = "Tells deploy.sh and the runbook which release mechanism this environment uses."
  value       = var.deployment_strategy
}

# During a shift this answers from the new task set while api_url still answers from the old one.
# It is where the gate runs, and the only way to compare the two versions before traffic moves.
output "test_url" {
  description = "Staged-rollout validation endpoint. Null where the strategy is rolling."
  value       = local.staged_rollout ? "http://${module.api.alb_dns_name}:8080" : null
}

output "rollback_alarm_names" {
  description = "The alarms that reverse a deployment."
  value       = module.api.rollback_alarm_names
}

output "gate_function_name" {
  description = "Deployment gate. Null where the strategy is rolling."
  value       = try(module.deployment_gate[0].function_name, null)
}

output "gate_log_group_name" {
  description = "Where the gate records its verdict and the cases that failed."
  value       = try(module.deployment_gate[0].log_group_name, null)
}

output "ingest_task_family" {
  value = module.ingest.task_definition_family
}

output "ingest_log_group_name" {
  value = module.ingest.log_group_name
}

output "subnet_ids" {
  description = "Needed by `aws ecs run-task` for the one-off ingestion job."
  value       = module.network.public_subnet_ids
}

output "tasks_security_group_id" {
  value = module.network.tasks_security_group_id
}
