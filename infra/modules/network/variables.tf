variable "name_prefix" {
  description = "Resource name prefix, e.g. rag-dev."
  type        = string
}

variable "cidr_block" {
  description = "VPC CIDR. Each environment gets its own so peering stays possible later."
  type        = string
  default     = "10.20.0.0/16"
}

variable "container_port" {
  description = "Port the API container listens on."
  type        = number
  default     = 8080
}

variable "ingress_cidrs" {
  description = "Sources allowed to reach the load balancer. Narrow this in prod."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "test_listener_port" {
  description = "Validation port for a staged rollout. 0 means the environment has no test listener."
  type        = number
  default     = 0
}

variable "test_ingress_cidrs" {
  description = "Sources allowed to reach the test listener. The deployment gate calls it from Lambda, whose egress address cannot be pinned, so a gated environment opens it and relies on the API key /ask already requires."
  type        = list(string)
  default     = []
}
