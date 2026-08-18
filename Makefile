# Ergonomic wrapper around pipelines/scripts/*.sh — the scripts are the source of truth, so a
# machine without make (or a CI runner) loses no capability. Every target below runs the same
# command the corresponding workflow does; nothing in the deployment path is make-only.
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Environments are addressed by their path under infra/envs, because that is what Terraform, the
# workflow inputs and the state key all use. One identifier, no translation table.
ENV        ?= nonprod/dev
AWS_REGION ?= us-east-1
VERSION    ?=
SCRIPTS    := pipelines/scripts
ENV_DIR     = infra/envs/$(ENV)
PY         := python

# The scripts read these from the environment, so exporting them here is the whole interface.
export AWS_REGION
export ENV
export VERSION

.PHONY: help check-tools bootstrap platform init plan deploy api-url api-key smoke eval \
        seed-corpus index-status promote-index rollback-index destroy fmt lint test ci

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- one-time account setup --------------------------------------------------

check-tools: ## Verify the local toolchain
	@bash $(SCRIPTS)/check_tools.sh

bootstrap: ## Create the Terraform state bucket and budget alarm (once per account)
	@bash $(SCRIPTS)/bootstrap.sh

platform: ## Apply the shared layer: OIDC provider, pipeline roles, ECR (once per account)
	@bash $(SCRIPTS)/platform.sh

# ---- environments ------------------------------------------------------------

init: ## terraform init for an environment (ENV=nonprod/dev)
	@terraform -chdir=$(ENV_DIR) init -input=false -reconfigure -backend-config="$(CURDIR)/infra/backend.hcl"

plan: init ## terraform plan for an environment
	@terraform -chdir=$(ENV_DIR) plan -input=false

deploy: ## Deploy a published release (ENV=nonprod/dev VERSION=v0.1.0)
	@bash $(SCRIPTS)/deploy.sh

api-url: ## Print the environment's base URL
	@terraform -chdir=$(ENV_DIR) output -raw api_url

smoke: ## Assert the environment serves the expected release (ENV=... [VERSION=...])
	@bash $(SCRIPTS)/smoke.sh "$$(terraform -chdir=$(ENV_DIR) output -raw api_url)" $(VERSION)

eval: ## Run the golden-set quality gate against an environment
	@RAG_API_KEY="$$(aws secretsmanager get-secret-value \
	  --secret-id "$$(terraform -chdir=$(ENV_DIR) output -raw api_key_secret_name)" \
	  --query SecretString --output text)" \
	 $(PY) eval/run_eval.py \
	  --base-url "$$(terraform -chdir=$(ENV_DIR) output -raw api_url)" \
	  --env "$(ENV)"

api-key: ## Print the environment's API key (for manual curl / Postman)
	@aws secretsmanager get-secret-value \
	  --secret-id "$$(terraform -chdir=$(ENV_DIR) output -raw api_key_secret_name)" \
	  --query SecretString --output text

# ---- index lifecycle ---------------------------------------------------------

seed-corpus: ## Upload data/raw to the environment's corpus prefix
	@bash $(SCRIPTS)/seed_corpus.sh

index-status: ## Show the promoted index version and what else is available
	@bash $(SCRIPTS)/promote_index.sh --status

promote-index: ## Point an environment at an index version (VERSION=v3-abc1234)
	@bash $(SCRIPTS)/promote_index.sh $(VERSION)

rollback-index: ## Flip the index pointer back to the previous version
	@bash $(SCRIPTS)/promote_index.sh --rollback

# ---- teardown ----------------------------------------------------------------

# The image variables have no defaults by design, so destroy has to supply throwaway values.
# Making them optional would let a real apply run with a placeholder image.
destroy: init ## Tear an environment down (ENV=nonprod/dev) — prompts before destroying
	@terraform -chdir=$(ENV_DIR) destroy \
	  -var "image=placeholder/rag-api:destroy" \
	  -var "ingest_image=placeholder/rag-ingest:destroy"

# ---- local quality gate ------------------------------------------------------

fmt: ## Format Python and Terraform in place
	@$(PY) -m ruff check --fix .
	@$(PY) -m black .
	@terraform fmt -recursive infra

lint: ## The same checks the PR gate runs — no writes
	@$(PY) -m ruff check .
	@$(PY) -m black --check .
	@terraform fmt -check -recursive infra

test: ## Unit tests with coverage, enforcing fail_under from pyproject.toml
	@$(PY) -m pytest

ci: lint test ## Everything the PR gate runs, locally
