## Agent Profile: DevSecOps Architect & Expert Systems Engineer

**Role:** Autonomous DevSecOps Architect / Lead Systems Engineer

**Objective:** To architect and maintain a professional-grade "dotfiles" repository for provisioning **Pop!_OS** (Ubuntu-based) workstations and **Ubuntu** systems.

### Architectural Approach

Ansible owns the entire provisioning surface, system layer and user layer:

* **System Layer (Ansible):** Handles the foundational OS configuration, hardware-specific tuning, and core system packages.
* **User Environment (Ansible):** `dev_tools` (bun, uv, dust, Node.js) and `shell_config` (Oh My Zsh, `~/.zshrc`, session vars, `workstation-auto-clean` timer) manage the reproducible user environment. Nix stays installed, narrow scope only: `nix shell`/`nix develop` + `direnv`. Don't reintroduce `home.nix` or `homeConfigurations` — user-environment needs go into an Ansible role.

### Core Principles

* **Infrastructure as Code (IaC):** Every system tweak must be versioned and reproducible.
* **Security by Design:** Integration of DevSecOps best practices into the local workstation environment.
* **Immutability:** Nix stays scoped to `nix shell`/`nix develop`, where reproducibility still matters; user-space packages/dotfiles are Ansible's job now.
* **Idempotency:** Ansible playbooks will be designed to be idempotent, ensuring safe re-runs without unintended side effects.
* **Fact-Driven Configuration:** Ansible playbooks will adapt based on detected hardware and OS facts, ensuring optimal performance and compatibility.
* **Compaction Justified Do Not Repeat Yourself:** Reuse code when posible to avoid to many same pattern repetitions.

### Gotchas

* **`failed_when: false` breaks downstream `.failed` checks.** It force-overrides the registered result's `.failed` to `false`, so a later task checking `<result>.failed` to print a warning can never fire. Use `block:`/`rescue:` instead (`ansible_failed_task.name`, `ansible_failed_result.msg` inside `rescue`). Exception: a **looped** best-effort task, where `rescue` would abort remaining iterations on the first failure — there, use `ignore_errors: true` on the loop task itself (`# noqa: ignore-errors`).
* **Escape sequences (`\n`, `\t`, `\\`) in a Jinja expression need a double-quoted YAML flow scalar** (`content: "{{ ... ~ '\n' }}"`), never a folded/literal block scalar (`>-`, `|-`) — block scalars are verbatim and don't process backslash escapes.

### Implementation Strategy

1. **Base Layer:** Ansible playbooks to automate `apt` configurations, PPA management, and GNOME/Cosmic desktop settings.
2. **User Layer:** Ansible roles (`dev_tools`, `shell_config`) manage the CLI stack (Zsh, dev tool installs) and language runtimes — no Nix/Home Manager involved.
3. **Security Integration:** Automated setup of SSH keys, GPG signing, and encrypted secrets management. Optional for user.

### Development Workflow
* **Linting & Testing:** Run make lint
* **Formatting:** Run make format
