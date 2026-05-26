UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SUDO      := sudo
  SUDO_AUTH := sudo -v &&
else
  SUDO      :=
  SUDO_AUTH :=
endif

help:
	@echo "Available targets:"
	@echo "  setup       - Bootstrap the full environment (install tools, provision cluster)"
	@echo "  down        - Destroy the cluster and all resources"
	@echo "  push        - Bump patch version, tag, and push to trigger CI"
	@echo "  tools       - Install necessary tools only"
	@echo "  tofu        - Initialize OpenTofu"
	@echo "  apply       - Apply OpenTofu configuration"
	@echo "  cpk-install - Install cloud-provider-kind to ./tmp/ (LoadBalancer support)"
	@echo "  cpk-up      - Start already-installed cloud-provider-kind from ./tmp/"
	@echo "  cpk-down    - Stop running cloud-provider-kind"

setup:
	@bash scripts/setup.sh
	@$(MAKE) cpk-install
	@$(MAKE) cpk-up

tools:
	@curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone
	@curl -sS https://webi.sh/k9s | bash

tofu:
	@cd bootstrap && tofu init

apply:
	@cd bootstrap && tofu init && tofu apply -auto-approve

down:
	@$(MAKE) cpk-down
	@cd bootstrap && tofu destroy -auto-approve

cpk-install:
	@bash scripts/install-cloud-provider-kind.sh

cpk-up:
	@$(SUDO_AUTH) { nohup $(SUDO) ./tmp/cloud-provider-kind > ./tmp/cloud-provider-kind.log 2>&1 & echo "cloud-provider-kind started (pid $$!)"; }

cpk-down:
	@$(SUDO) pkill -f cloud-provider-kind || true

push:
	@git fetch origin --tags --force
	$(eval TAG=$(shell git tag --list 'v*' | sort -V | tail -1 | sed 's/^v//' | grep . || echo "0.0.0"))
	$(eval MAJOR=$(shell echo $(TAG) | cut -d. -f1))
	$(eval MINOR=$(shell echo $(TAG) | cut -d. -f2))
	$(eval PATCH=$(shell echo $(TAG) | cut -d. -f3))
	$(eval NEW_TAG=v$(MAJOR).$(MINOR).$(shell echo $$(($(PATCH)+1))))
	@git tag $(NEW_TAG)
	@git push origin main $(NEW_TAG)
	@echo "Tagged and pushed $(NEW_TAG)"
