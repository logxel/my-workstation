{ lib, pkgs, username, homeDirectory, editorCommand, ... }:

let
  cleanupPolicy = {
    downloads = {
      enabled = true;
      path = "${homeDirectory}/Downloads";
      maxAgeDays = 90;
    };
    directories = {
      enabled = true;
      items = [
        {
          path = "${homeDirectory}/.bun/install/cache";
          maxAgeDays = 30;
        }
        {
          path = "${homeDirectory}/.cache/cargo-target";
          maxAgeDays = 14;
        }
        {
          path = "${homeDirectory}/.cache/go-build";
          maxAgeDays = 14;
        }
        {
          path = "${homeDirectory}/.cache/go/pkg/mod";
          maxAgeDays = 30;
        }
      ];
    };
    tools = {
      direnv.enabled = true;
      nix = {
        enabled = true;
        maxAgeDays = 30;
      };
      uv.enabled = true;
    };
  };

  cleanupTargets = lib.concatMapStringsSep "\n" (item: ''    ${lib.escapeShellArg item.path}:::${toString item.maxAgeDays}'') cleanupPolicy.directories.items;

  cleanupScript = pkgs.writeShellApplication {
    name = "workstation-auto-clean";
    runtimeInputs = with pkgs; [ coreutils direnv findutils nix uv ];
    text = ''
            set -Eeuo pipefail

            clean_old_files() {
              local target="$1"
              local age_days="$2"

              if [[ ! -d "$target" ]]; then
                return 0
              fi

              find "$target" -mindepth 1 \( -type f -o -type l \) -mtime +"$age_days" -print -delete
              find "$target" -mindepth 1 -depth -type d -empty -mtime +"$age_days" -print -delete
            }

            run_if_available() {
              local binary="$1"
              shift

              if ! command -v "$binary" >/dev/null 2>&1; then
                return 0
              fi

              if ! "$@"; then
                printf 'Skipping failed cleanup command: %s\n' "$*" >&2
              fi
            }

            ${lib.optionalString cleanupPolicy.downloads.enabled ''
              clean_old_files ${lib.escapeShellArg cleanupPolicy.downloads.path} ${toString cleanupPolicy.downloads.maxAgeDays}
            ''}

            ${lib.optionalString cleanupPolicy.directories.enabled ''
              cache_targets=(
      ${cleanupTargets}
              )

              for target_config in "''${cache_targets[@]}"; do
                target_path="''${target_config%%:::*}"
                target_age_days="''${target_config##*:::}"
                clean_old_files "$target_path" "$target_age_days"
              done
            ''}

            ${lib.optionalString cleanupPolicy.tools.uv.enabled ''
              run_if_available uv uv cache prune
            ''}

            ${lib.optionalString cleanupPolicy.tools.direnv.enabled ''
              run_if_available direnv direnv prune
            ''}

            ${lib.optionalString cleanupPolicy.tools.nix.enabled ''
              run_if_available nix-collect-garbage nix-collect-garbage --delete-older-than ${toString cleanupPolicy.tools.nix.maxAgeDays}d
            ''}
    '';
  };

  npmCompatScript = pkgs.writeShellScript "npm" ''
    #!/usr/bin/env bash
    exec ${lib.getExe pkgs.bun} "$@"
  '';

  npxCompatScript = pkgs.writeShellScript "npx" ''
    #!/usr/bin/env bash
    exec ${lib.getExe' pkgs.bun "bunx"} "$@"
  '';

  yarnCompatScript = pkgs.writeShellScript "yarn" ''
    #!/usr/bin/env bash
    exec ${lib.getExe pkgs.bun} "$@"
  '';

  pnpmCompatScript = pkgs.writeShellScript "pnpm" ''
    #!/usr/bin/env bash
    exec ${lib.getExe pkgs.bun} "$@"
  '';

in
{
  home = {
    inherit username homeDirectory;
    stateVersion = "25.05";
  };

  programs = {
    # Enable Home Manager; conflicting shell dotfiles are backed up by Ansible.
    home-manager.enable = true;

    # Zsh is configured declaratively so shell behaviour is reproducible and does
    # not depend on post-install curl/bash bootstrap scripts.
    zsh = {
      enable = true;
      autocd = true;
      autosuggestion.enable = true;
      enableCompletion = true;
      syntaxHighlighting.enable = true;
      initContent = lib.mkBefore ''
        if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
          . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        elif [[ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]]; then
          . "$HOME/.nix-profile/etc/profile.d/nix.sh"
        fi
      '';
      oh-my-zsh = {
        enable = true;
        plugins = [ "git" ];
        theme = "robbyrussell";
      };
      shellAliases = {
        # nix home manager new magic shortcut to apply it in one command after updating this configuration:
        hms = "DOTFILES_USER=$(whoami) DOTFILES_HOME=$HOME nix --extra-experimental-features 'nix-command flakes' run --impure ./nix#homeConfigurations.x86_64-linux.activationPackage";
        opencode = "~/.opencode/bin/opencode";
        ll = "ls -lah";
        copilot = "${lib.getExe pkgs.github-copilot-cli}";
        cargo-release = "CARGO_INCREMENTAL=0 RUSTFLAGS='-C target-cpu=native -C codegen-units=1' cargo build --release";
        go-release = "GOMAXPROCS=$(nproc) go build ./...";
        npm = "bun";
        npx = "bunx";
        yarn = "bun";
        pnpm = "bun";
      };
    };

    direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableZshIntegration = true;
    };
  };

  home.packages = with pkgs; [
    bun
    dust
    github-copilot-cli
    nodejs_24
    ripgrep
    opencode
    uv
    warp-terminal
  ];

  home.sessionVariables = {
    EDITOR = editorCommand;
    VISUAL = editorCommand;
    BUN_INSTALL = "${homeDirectory}/.bun";
    CARGO_HOME = "${homeDirectory}/.local/share/cargo";
    RUSTUP_HOME = "${homeDirectory}/.rustup";
    CARGO_TARGET_DIR = "${homeDirectory}/.cache/cargo-target";
    GOCACHE = "${homeDirectory}/.cache/go-build";
    GOMODCACHE = "${homeDirectory}/.cache/go/pkg/mod";
    GOPATH = "${homeDirectory}/.local/share/go";
  };

  # NOTE: After adding new paths here, run `hms` then log out and back in
  # (or reboot). Home Manager's hm-session-vars.sh exports a guard
  # (__HM_SESS_VARS_SOURCED) that prevents updates from taking effect in
  # existing sessions. A fresh login is the official procedure.
  home.sessionPath = [
    "${homeDirectory}/.bun/bin"
    "${homeDirectory}/.local/share/cargo/bin"
    "${homeDirectory}/.local/bin"
  ];

  home.file.".local/bin/npm" = {
    executable = true;
    source = npmCompatScript;
  };

  home.file.".local/bin/npx" = {
    executable = true;
    source = npxCompatScript;
  };

  home.file.".local/bin/yarn" = {
    executable = true;
    source = yarnCompatScript;
  };

  home.file.".local/bin/pnpm" = {
    executable = true;
    source = pnpmCompatScript;
  };

  home.activation.createBuildCaches = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p \
      "$HOME/.bun" \
      "$HOME/.cache/cargo-target" \
      "$HOME/.cache/go-build" \
      "$HOME/.cache/go/pkg/mod" \
      "$HOME/.local/share/cargo" \
      "$HOME/.local/share/go" \
      "$HOME/.rustup" \
      "$HOME/.local/bin"
  '';

  systemd.user.services.workstation-auto-clean = {
    Unit.Description = "Clean stale files and developer tool caches";
    Service = {
      Type = "oneshot";
      ExecStart = "${cleanupScript}/bin/workstation-auto-clean";
    };
  };

  systemd.user.timers.workstation-auto-clean = {
    Unit.Description = "Run periodic cleanup for stale files and developer tool caches";
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
      Unit = "workstation-auto-clean.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
