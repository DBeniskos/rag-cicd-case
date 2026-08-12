# Ergonomic wrapper around pipelines/scripts/*.sh — the scripts are the source of truth,
# so a machine without make (or a CI runner) loses no capability.
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV        ?= dev
AWS_REGION ?= us-east-1
VERSION    ?=
SCRIPTS    := pipelines/scripts

export AWS_REGION

.PHONY: help check-tools bootstrap platform plan deploy smoke eval promote-index rollback-index destroy fmt lint test build ci

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check-tools: ## Verify the local toolchain
	@bash $(SCRIPTS)/check_tools.sh

bootstrap: ## Create the Terraform state bucket in an account (ACCOUNT=nonprod|prod)
	@bash $(SCRIPTS)/bootstrap.sh $(ACCOUNT)

platform: ## Apply the shared layer: OIDC provider, pipeline roles, ECR (ACCOUNT=nonprod|prod)
	@bash $(SCRIPTS)/platform.sh $(ACCOUNT)

plan: ## terraform plan for an environment
	@bash $(SCRIPTS)/terraform.sh plan $(ENV)

deploy: ## Apply infra and roll out a release (ENV=dev VERSION=v0.1.0)
	@bash $(SCRIPTS)/deploy.sh $(ENV) $(VERSION)

smoke: ## Hit /healthz and /version against an environment
	@bash $(SCRIPTS)/smoke.sh $(ENV)

eval: ## Run the golden-set eval harness against an environment
	@bash $(SCRIPTS)/eval.sh $(ENV)

promote-index: ## Point an environment at an index version (VERSION=v3-abc1234)
	@bash $(SCRIPTS)/promote_index.sh $(ENV) $(VERSION)

rollback-index: ## Flip the index pointer back to the previous version
	@bash $(SCRIPTS)/promote_index.sh $(ENV) --previous

destroy: ## Tear an environment down
	@bash $(SCRIPTS)/destroy.sh $(ENV)

fmt: ## Format Python and Terraform in place
	@bash $(SCRIPTS)/fmt.sh

lint: ## Lint Python and Terraform (no writes) — same checks CI runs
	@bash $(SCRIPTS)/lint.sh

test: ## Run unit tests with coverage
	@bash $(SCRIPTS)/test.sh

build: ## Build both container images locally
	@bash $(SCRIPTS)/build.sh $(if $(VERSION),$(VERSION),local)

ci: lint test ## Everything the PR gate runs, locally
