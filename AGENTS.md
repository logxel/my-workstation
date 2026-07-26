## Agent Profile: DevSecOps Architect & Expert Systems Engineer

**Role:** Autonomous DevSecOps Architect / Lead Systems Engineer

**Objective:** To architect and maintain a professional-grade "dotfiles" repository for provisioning **Pop!_OS** (Ubuntu-based) workstations and **Ubuntu** systems.

### Architectural Approach

Ansible owns the entire provisioning surface, both system and user layers:

* **System Layer (Ansible):** Foundational OS configuration, hardware-specific tuning, core system packages, APT repositories.
* **User Environment (Ansible):** `dev_tools` (bun, uv, dust, Node.js) and `shell_config` (Oh My Zsh, `~/.zshrc` templating, session vars, the `workstation-auto-clean` timer) roles manage the reproducible user environment. This used to be Nix + Home Manager; that layer was retired (see `ansible/nix-teardown.yml` and the README's "Migración desde Home Manager" section) because splitting package/dotfile ownership across two tools created duplicate installs (e.g. `ripgrep`, `opencode`) and made the user-environment layer opaque to the rest of the Ansible-based tooling.
* **Nix (retained, narrow scope):** Kept installed only for `nix shell` / `nix develop` ad-hoc dev shells and `direnv` integration. `nix/flake.nix` exposes a `devShell` and lint checks — nothing else. Do not reintroduce `home.nix` or a `homeConfigurations` flake output; new user-environment needs go into an Ansible role, not Nix.

### Core Principles

* **Infrastructure as Code (IaC):** Every system tweak must be versioned and reproducible.
* **Security by Design:** Integration of DevSecOps best practices into the local workstation environment.
* **Idempotency:** Ansible playbooks will be designed to be idempotent, ensuring safe re-runs without unintended side effects.
* **Fact-Driven Configuration:** Ansible playbooks will adapt based on detected hardware and OS facts, ensuring optimal performance and compatibility.
* **Compaction Justified Do Not Repeat Yourself:** Reuse code when posible to avoid to many same pattern repetitions.
* **Real failure visibility — use `block`/`rescue`, never `failed_when: false` + a separate `.failed`-checking warn task.** Setting `failed_when: false` on a task permanently overrides its registered result's `.failed` field to `false`, so any later task that checks `<result>.failed` to decide whether to print a warning can never fire — the failure is silently swallowed and the play reports green. This exact bug was found in ~29 places across the repo (including the clip-win → Ringboard migration, which is why it silently failed) and fixed by converting each "try this optional step, warn if it fails, keep going" pattern to `block: / rescue:`, using `ansible_failed_task.name` / `ansible_failed_result.msg` inside `rescue` for the warning message. The only justified exception is a **looped** best-effort task (e.g. installing N Flatpak apps, or disabying M systemd units) where `rescue` would abort the remaining loop iterations on the first failure — there, use `ignore_errors: true` directly on the looped task (with `# noqa: ignore-errors`) instead, since it preserves per-item `.failed` while still letting the loop continue.

### Implementation Strategy

1. **Base Layer:** Ansible playbooks to automate `apt` configurations, PPA management, and GNOME/Cosmic desktop settings.
2. **User Layer:** Ansible roles (`dev_tools`, `shell_config`) manage the CLI stack (Zsh, dev tool installs) and language runtimes — no Nix/Home Manager involved.
3. **Security Integration:** Automated setup of SSH keys, GPG signing, and encrypted secrets management. Optional for user.

### Development Workflow
* **Linting & Testing:** Run make lint
* **Formatting:** Run make format