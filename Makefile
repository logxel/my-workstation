.PHONY: lint lint-ansible lint-nix format format-ansible format-nix check-ansible-tools check-nix-tools bootstrap ansible-requirements playbook install-feature apt-clean nix-clean nix-migrate-single-user

NIX_DIR := ./nix
ANSIBLE_DIR := ansible
ANSIBLE_REQUIREMENTS_FILE := $(ANSIBLE_DIR)/requirements.yml
DOTFILES_USER ?= $(shell id -un)
DOTFILES_HOME ?= $(HOME)
NIX_SYSTEM ?= $(shell nix eval --impure --raw --expr builtins.currentSystem)

define require_command
	@command -v $(1) >/dev/null 2>&1 || { echo "Missing required command: $(1)"; exit 127; }
endef

lint: lint-ansible lint-nix

bootstrap:
	@echo "Running bootstrap script..."
	@bash ./bootstrap.sh

ansible-requirements:
	$(call require_command,ansible-galaxy)
	ansible-galaxy collection install -r $(ANSIBLE_REQUIREMENTS_FILE)

check-ansible-tools:
	$(call require_command,ansible-playbook)
	$(call require_command,ansible-lint)
	$(call require_command,yamllint)

check-ansible-runtime:
	$(call require_command,ansible-playbook)

check-nix-tools:
	$(call require_command,nix)
	$(call require_command,statix)

ansible-tags ?= all
features ?=

playbook:
	@$(MAKE) check-ansible-runtime
	ansible-playbook $(ANSIBLE_DIR)/local.yml --tags "$(ansible-tags)" -K

install-feature:
	@if [ -z "$(features)" ]; then echo "Usage: make install-feature features=thunderbird"; exit 2; fi
	@$(MAKE) check-ansible-runtime
	ansible-playbook $(ANSIBLE_DIR)/local.yml --extra-vars "dotfiles_only_features=$(features)" -K

apt-clean:
	@$(MAKE) check-ansible-runtime
	ansible-playbook $(ANSIBLE_DIR)/apt-clean.yml

nix-clean:
	@$(MAKE) check-ansible-runtime
	ansible-playbook $(ANSIBLE_DIR)/nix-clean.yml

nix-migrate-single-user:
	@$(MAKE) check-ansible-runtime
	ansible-playbook $(ANSIBLE_DIR)/nix-migrate-single-user.yml -K

lint-ansible:
	@$(MAKE) check-ansible-tools
	ansible-playbook --syntax-check $(ANSIBLE_DIR)/local.yml
	ansible-lint $(ANSIBLE_DIR)
	yamllint .

lint-nix:
	@$(MAKE) check-nix-tools
	statix check $(NIX_DIR)
	DOTFILES_USER="$(DOTFILES_USER)" DOTFILES_HOME="$(DOTFILES_HOME)" NIX_SYSTEM="$(NIX_SYSTEM)" nix --extra-experimental-features "nix-command flakes" flake check --impure $(NIX_DIR)

format: format-ansible format-nix

format-ansible:
	@$(MAKE) check-ansible-tools
	ansible-lint --fix $(ANSIBLE_DIR)

format-nix:
	@$(MAKE) check-nix-tools
	cd $(NIX_DIR) && nix fmt .

