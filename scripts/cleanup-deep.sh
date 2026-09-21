#!/usr/bin/env bash
#
# cleanup-deep.sh — reclaim disk space on this workstation.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/cleanup-deep.sh --dry-run              # show what would happen
  ./scripts/cleanup-deep.sh                        # run the SAFE tier only
  ./scripts/cleanup-deep.sh --rustup               # + drop old Rust toolchains
  ./scripts/cleanup-deep.sh --docker-keep-days 3   # docker retention (default 7)
  ./scripts/cleanup-deep.sh --docker-aggressive    # + stopped containers / volumes

Tier 1 (default) only touches regenerable caches. Nothing in it loses data or
requires reconfiguration.

Tier 2 (--docker-aggressive) is destructive. It removes stopped containers and
can remove volumes, which may hold database data for project stacks. It prompts
before doing anything.
EOF
}

DRY_RUN=0
DO_RUSTUP=0
DO_DOCKER_AGGRESSIVE=0
DOCKER_KEEP_DAYS=7

while (($# > 0)); do
  case "$1" in
    --dry-run)           DRY_RUN=1; shift ;;
    --rustup)            DO_RUSTUP=1; shift ;;
    --docker-aggressive) DO_DOCKER_AGGRESSIVE=1; shift ;;
    --docker-keep-days)  DOCKER_KEEP_DAYS="${2:?--docker-keep-days needs a number}"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

DOCKER_KEEP_HOURS=$(( DOCKER_KEEP_DAYS * 24 ))

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

trap 'printf "\n\033[31mFAILED: line %s, exit %s\033[0m\n" "$LINENO" "$?" >&2' ERR

avail_bytes() { df --output=avail -B1 / | tail -1; }

# Run a command, tolerating failure (a missing tool must not abort the run).
run() {
  printf '  $ %s\n' "$*"
  if ((DRY_RUN)); then return 0; fi
  "$@" || printf '    -> failed, continuing\n' >&2
}

# Run a binary only if it exists (avoids `set -e` aborting on an absent tool).
run_if_exists() {
  local bin="$1"; shift
  [[ -x "$bin" ]] || { printf '  skip (not installed): %s\n' "$bin"; return 0; }
  run "$bin" "$@"
}

# Delete a path if it exists, printing its size first.
rm_path() {
  local target="$1"
  [[ -e "$target" ]] || return 0
  local size
  size="$(du -xsh "$target" 2>/dev/null | cut -f1 || true)"
  printf '  remove %s (%s)\n' "$target" "$size"
  if ((DRY_RUN)); then return 0; fi
  rm -rf -- "$target"
}

BEFORE="$(avail_bytes)"
printf '\033[1mFree space before: %s\033[0m\n' "$(numfmt --to=iec "$BEFORE")"
((DRY_RUN)) && printf '\033[33mDRY RUN — nothing will be deleted\033[0m\n'

# ---------------------------------------------------------------- Tier 1
# Build cache and dangling images are regenerable build output, never data.
# `until` keeps anything created within the retention window (default 7 days).
step "Docker build cache (keeping last ${DOCKER_KEEP_DAYS} days)"
run docker builder prune -af --filter "until=${DOCKER_KEEP_HOURS}h"

step "Docker dangling images (keeping last ${DOCKER_KEEP_DAYS} days)"
run docker image prune -f --filter "until=${DOCKER_KEEP_HOURS}h"

# Zed accumulates Node runtimes and their caches. The cache subtree is
# regenerable; the node-* runtime dir is left alone.
step "Zed node cache (reclaims ~4.5 GB)"
rm_path "$HOME/.local/share/zed/node/cache"

step "Package manager caches"
# Verified sizes on this host: bun cache ~34 MB, cargo download cache ~231 MB,
# pip ~19 MB. The large ~/.bun/install (2.3 GB) and ~/.local/share/uv (918 MB)
# hold *installed* toolchains/packages, not caches, so they are left alone.
rm_path "$HOME/.bun/install/cache"        # bun download cache
run_if_exists "$HOME/.bun/bin/bun" pm cache rm
command -v npm >/dev/null && run npm cache clean --force
run_if_exists "$HOME/.local/bin/uv" cache clean
# Cargo download cache only - leaves ~/.cargo/registry/src and git checkouts intact.
rm_path "$HOME/.cargo/registry/cache"
rm_path "$HOME/.cache/pip"
note "pnpm store (~/.local/share/pnpm/store, 605 MB) left alone: it is"
note "hard-linked into existing node_modules, so pruning can corrupt projects."

step "Application caches"
rm_path "$HOME/.cache/BraveSoftware"
rm_path "$HOME/.cache/gnome-software"
rm_path "$HOME/.cache/mesa_shader_cache_db"

step "Flatpak: unused runtimes"
run flatpak uninstall --unused -y

step "System: apt cache, package lists, journal"
if ((DRY_RUN)); then
  note "would run: apt-get clean, rm /var/lib/apt/lists/*, journalctl --vacuum-size=100M"
elif sudo -n true 2>/dev/null; then
  sudo apt-get clean
  sudo rm -rf /var/lib/apt/lists/*   # repopulated by the next `apt update`
  sudo journalctl --vacuum-size=100M
else
  note "no non-interactive sudo available - run these yourself:"
  note "  sudo apt-get clean"
  note "  sudo rm -rf /var/lib/apt/lists/*"
  note "  sudo journalctl --vacuum-size=100M"
fi

# ---------------------------------------------------------------- Tier 1 (opt-in)
if ((DO_RUSTUP)); then
  step "Rust toolchains (opt-in)"
  note "installed:"
  rustup toolchain list | sed 's/^/      /'
  for tc in nightly-2026-07-14-x86_64-unknown-linux-gnu 1.96-x86_64-unknown-linux-gnu; do
    if rustup toolchain list | grep -q "^${tc}"; then
      run rustup toolchain uninstall "$tc"
    fi
  done
fi

# ---------------------------------------------------------------- Tier 2
if ((DO_DOCKER_AGGRESSIVE)); then
  step "DESTRUCTIVE docker cleanup"
  cat <<'WARN'
    This will:
      * remove ALL stopped containers
        -> including plataforma-ciudadana_devcontainer-workspace-1 (~5.4 GB,
           re-creatable from the devcontainer config, but any packages installed
           inside it are lost)
      * remove images not used by a RUNNING container
        -> stopped project stacks will need a rebuild before they can start
      * remove dangling (unreferenced) volumes
    It does NOT touch the 7 running containers.
WARN
  printf '\n    Type exactly "yes" to proceed: '
  read -r reply
  if [[ "$reply" == "yes" ]]; then
    run docker container prune -f
    run docker image prune -a -f
    note "dangling volumes only:"
    run docker volume prune -f
  else
    note "skipped"
  fi
fi

# ---------------------------------------------------------------- Report
AFTER="$(avail_bytes)"
((DRY_RUN)) || printf '\n\033[1mFree before: %s   Free after: %s   Reclaimed: %s\033[0m\n' \
  "$(numfmt --to=iec "$BEFORE")" \
  "$(numfmt --to=iec "$AFTER")" \
  "$(numfmt --to=iec $(( AFTER - BEFORE )))"
df -h /
