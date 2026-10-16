SHELL := /usr/bin/env bash
CHART   := helm/charts/data-sync
RELEASE := data-sync

.PHONY: help lint template render check-render kustomize secret-checksum ansible-syntax ansible-lint all

help: ## Show the targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

# Lint and render each values layer separately: a value that is fine in
# staging can still break production.
lint: ## helm lint for default, staging and production values
	helm lint $(CHART)
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values.staging.yaml
	helm lint $(CHART) -f $(CHART)/values.yaml -f $(CHART)/values.production.yaml

template: ## helm template for default, staging and production values
	helm template $(RELEASE) $(CHART) -n data-sync > /dev/null
	helm template $(RELEASE) $(CHART) -n data-sync-staging -f $(CHART)/values.yaml -f $(CHART)/values.staging.yaml > /dev/null
	helm template $(RELEASE) $(CHART) -n data-sync -f $(CHART)/values.yaml -f $(CHART)/values.production.yaml > /dev/null

# Scripts are run through bash rather than ./script so they still work if the
# executable bit is lost (e.g. files uploaded through the GitHub web UI).
render: ## Regenerate the kustomize base from the chart (production values)
	bash scripts/render-base.sh

# Needs a git repo: it compares the freshly rendered file with the committed one.
check-render: render ## Fail if the committed kustomize base is out of date
	@git diff --exit-code standard/data-sync/base/helm-output.yaml \
	  || { echo "helm-output.yaml is out of date: run 'make render' and commit the result." >&2; exit 1; }

kustomize: ## Build the production overlay
	kubectl kustomize standard/data-sync/production

secret-checksum: ## Sync ESO, then set SECRET_CHECKSUM to the AWS secret version ID (needs aws + kubectl)
	bash scripts/secret-checksum.sh

ansible-syntax: ## ansible-playbook --syntax-check
	cd ansible && ansible-playbook playbooks/playbook-data-sync.yml --syntax-check

ansible-lint: ## ansible-lint with the production profile
	cd ansible && ansible-lint

all: lint template render ansible-syntax ansible-lint ## Everything CI runs
	@$(MAKE) --no-print-directory kustomize > /dev/null && echo "kustomize build: OK"
