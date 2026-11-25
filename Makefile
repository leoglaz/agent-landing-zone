.DEFAULT_GOAL := help

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENVIRONMENT ?= dev
ENV ?= $(ENVIRONMENT)
BACKEND_CONFIG ?= $(ROOT_DIR)/environments/$(ENV)/backend.json
VAR_FILE ?= $(ROOT_DIR)/environments/$(ENV)/terraform.tfvars
PLAN_FILE := $(ROOT_DIR)/environments/$(ENV)/platform.tfplan
TERRAFORM ?= terraform
AZ ?= az
export TF_DATA_DIR := $(ROOT_DIR)/.terraform/environments/$(ENV)

.NOTPARALLEL:
.PHONY: help bootstrap init plan apply output validate check-tools check-inputs

help:
	@printf '%s\n' \
		'make bootstrap ENV=dev   Alias for init; initialize the existing remote backend' \
		'make init ENV=dev        Initialize Terraform providers, modules and remote state' \
		'make plan ENV=dev        Initialize and save an infrastructure plan' \
		'make apply ENV=dev       Create a fresh plan, then apply that exact plan' \
		'make output ENV=dev      Read Terraform outputs' \
		'make validate            Check Terraform offline (requires provider/module downloads)' \
		'Backend settings, including the complete state key, live in environments/<env>/backend.json.' \
		'Copy environments/dev/backend.json.example to backend.json and set your state settings.' \
		'Copy environments/dev/terraform.tfvars.example to terraform.tfvars and set your inputs.' \
		'ENVIRONMENT is an alias for ENV. No azd or Task installation is required.' \
		'Infrastructure only: application builds and post-provision service configuration are not run.'

check-tools:
	@case "$(ENV)" in ""|*[!A-Za-z0-9_-]*) echo "ENV must contain only letters, digits, underscores and hyphens." >&2; exit 1 ;; esac
	@command -v "$(TERRAFORM)" >/dev/null || { echo "Terraform is required." >&2; exit 1; }
	@test -z "$${ARM_ACCESS_KEY:-}" && test -z "$${ARM_SAS_TOKEN:-}" || { \
		echo "Remove ARM_ACCESS_KEY and ARM_SAS_TOKEN; state requires Entra authentication." >&2; exit 1; \
	}

bootstrap: init

init: check-tools
	@test -f "$(BACKEND_CONFIG)" || { echo "Missing backend config: $(BACKEND_CONFIG); copy and edit backend.json.example first." >&2; exit 1; }
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" init -input=false -lockfile=readonly \
		-backend-config="$(abspath $(BACKEND_CONFIG))" \
		-backend-config=use_azuread_auth=true -backend-config=use_cli=true -backend-config=lookup_blob_endpoint=true

check-inputs: check-tools
	@command -v "$(AZ)" >/dev/null || { echo "Azure CLI is required; run az login first." >&2; exit 1; }
	@set -eu; \
	test -f "$(VAR_FILE)" || { echo "Missing $(VAR_FILE); copy and edit terraform.tfvars.example first." >&2; exit 1; }; \
	subscription=$$(sed -nE 's/^[[:space:]]*subscriptionId[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$$/\1/p' "$(VAR_FILE)"); \
	printf '%s\n' "$$subscription" | grep -Eq '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$$' || { \
		echo "Set subscriptionId to a GUID in $(VAR_FILE)." >&2; exit 1; \
	}; \
	active=$$("$(AZ)" account show --query id --output tsv --only-show-errors); \
	test "$$(printf '%s' "$$active" | tr '[:upper:]' '[:lower:]')" = "$$(printf '%s' "$$subscription" | tr '[:upper:]' '[:lower:]')" || { \
		echo "Azure CLI subscription differs from $(VAR_FILE). Run az account set --subscription $$subscription first." >&2; exit 1; \
	}

plan: check-inputs init
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" plan -input=false -lock-timeout=5m \
		-var-file="$(abspath $(VAR_FILE))" -out="$(PLAN_FILE)"

apply: plan
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" apply -input=false -lock-timeout=5m "$(PLAN_FILE)"

output: init
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" output

validate: export TF_DATA_DIR := $(ROOT_DIR)/.terraform/validate
validate: check-tools
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" fmt -check
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" init -backend=false -lockfile=readonly
	"$(TERRAFORM)" -chdir="$(ROOT_DIR)/infra/terraform" validate
