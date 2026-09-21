#!/usr/bin/env bash
#
# cleanup-volumes.sh — targeted Docker volume reclaim.
#
# Removals are gated on AGE, not on whether a container happens to be running:
# a devcontainer that exited an hour ago is still in active use.

set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/cleanup-volumes.sh --dry-run                 # preview, run this first
  ./scripts/cleanup-volumes.sh --devcontainer            # devcontainer state
  ./scripts/cleanup-volumes.sh --caches                  # regenerable caches
  ./scripts/cleanup-volumes.sh --mongo-orphans           # orphaned MongoDB data
  ./scripts/cleanup-volumes.sh --orphan-data             # orphaned application data
  sudo ./scripts/cleanup-volumes.sh --mongo-orphans      # root needed, see gate 3

Safety gate — a volume is removed only when ALL of these hold:
  1. No RUNNING container mounts it.
  2. Its last evidence of use is at least --min-age-days old (default 7).
     Docker exposes no "last used" field on volumes, so this is reconstructed
     from the newest of: the referencing containers' Created/StartedAt/
     FinishedAt, and the newest file mtime under the mountpoint. A container
     that merely EXITED recently still counts as recent use.
  3. If there is no evidence at all, the volume is REFUSED. For a volume with
     no container left, the mountpoint mtime is the only remaining evidence
     and reading it needs root, so those tiers require sudo.

Override the minimum with --min-age-days N or CLEANUP_MIN_AGE_DAYS=N.

Volume identities were verified by inspection, not inferred from Docker's
"orphan" label — see the notes on each tier below.
EOF
}

DRY_RUN=0
DO_DEVCONTAINER=0
DO_CACHES=0
DO_MONGO_ORPHANS=0
DO_ORPHAN_DATA=0
MIN_AGE_DAYS="${CLEANUP_MIN_AGE_DAYS:-7}"

while (($# > 0)); do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --devcontainer)  DO_DEVCONTAINER=1; shift ;;
    --caches)        DO_CACHES=1; shift ;;
    --mongo-orphans) DO_MONGO_ORPHANS=1; shift ;;
    --orphan-data)   DO_ORPHAN_DATA=1; shift ;;
    --min-age-days)  MIN_AGE_DAYS="${2:?--min-age-days requires a value}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || {
  printf 'min age must be a whole number of days, got %q\n' "$MIN_AGE_DAYS" >&2; exit 2; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
trap 'printf "\n\033[31mFAILED: line %s, exit %s\033[0m\n" "$LINENO" "$?" >&2' ERR

avail_bytes() { df --output=avail -B1 / | tail -1; }

# Docker emits RFC3339 with nanoseconds. The zero date (0001-01-01) means "never
# happened" and must not be mistaken for evidence of use.
epoch_of() {
  local ts="$1" clean e
  [[ -n "$ts" ]] || return 1
  clean="$(printf '%s' "$ts" | sed -E 's/\.[0-9]+Z$/Z/')"
  e="$(date -d "$clean" +%s 2>/dev/null)" || return 1
  ((e > 0)) || return 1
  printf '%s' "$e"
}

# Newest evidence that a volume was used. Prints "<epoch> <basis>"; returns 1
# when nothing at all is known.
volume_last_used() {
  local vol="$1" best=0 basis="" cid e f mp
  while read -r cid; do
    [[ -n "$cid" ]] || continue
    if [[ "$(docker inspect "$cid" --format '{{.State.Running}}' 2>/dev/null)" == "true" ]]; then
      printf '%s running' "$(date +%s)"
      return 0
    fi
    for f in '{{.Created}}' '{{.State.StartedAt}}' '{{.State.FinishedAt}}'; do
      e="$(epoch_of "$(docker inspect "$cid" --format "$f" 2>/dev/null)")" || continue
      if ((e > best)); then best="$e"; basis="container"; fi
    done
  done < <(docker ps -a --filter "volume=$vol" --format '{{.ID}}' 2>/dev/null)

  mp="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [[ -n "$mp" && -r "$mp" ]]; then
    e="$(find "$mp" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1 || true)"
    if [[ -n "$e" ]] && ((e > best)); then best="$e"; basis="mtime"; fi
  fi

  ((best > 0)) || return 1
  printf '%s %s' "$best" "$basis"
}

remove_vol() {
  local vol="$1"
  docker volume inspect "$vol" >/dev/null 2>&1 || return 0

  if [[ -n "$(docker ps --filter "volume=$vol" -q 2>/dev/null)" ]]; then
    printf '  \033[33mREFUSED (mounted by a running container): %s\033[0m\n' "$vol"
    return 0
  fi

  # A readable, empty volume has nothing to lose, so age does not apply.
  local mp contents
  mp="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [[ -n "$mp" && -r "$mp" ]] && contents="$(ls -A "$mp" 2>/dev/null)" && [[ -z "$contents" ]]; then
    printf '  remove %s   (empty volume)\n' "$vol"
    ((DRY_RUN)) || docker volume rm "$vol" >/dev/null 2>&1 \
      || printf '    -> failed, continuing\n' >&2
    return 0
  fi

  local lu lu_epoch lu_basis age age_days age_h
  if ! lu="$(volume_last_used "$vol")"; then
    printf '  \033[33mREFUSED (no evidence of last use; re-run with sudo so the mountpoint mtime is readable): %s\033[0m\n' "$vol"
    return 0
  fi
  lu_epoch="${lu%% *}"; lu_basis="${lu##* }"
  age=$(( $(date +%s) - lu_epoch ))
  age_days=$(( age / 86400 )); age_h=$(( (age % 86400) / 3600 ))

  if ((age < MIN_AGE_DAYS * 86400)); then
    printf '  \033[33mREFUSED (last use %sd %sh ago, under the %sd minimum, via %s): %s\033[0m\n' \
      "$age_days" "$age_h" "$MIN_AGE_DAYS" "$lu_basis" "$vol"
    return 0
  fi

  printf '  remove %s   (last use %sd %sh ago, via %s)\n' "$vol" "$age_days" "$age_h" "$lu_basis"
  ((DRY_RUN)) || docker volume rm "$vol" >/dev/null 2>&1 \
    || printf '    -> failed, continuing\n' >&2
}

BEFORE="$(avail_bytes)"
printf '\033[1mFree before: %s   minimum age: %s days\033[0m\n' \
  "$(numfmt --to=iec "$BEFORE")" "$MIN_AGE_DAYS"
((DRY_RUN)) && printf '\033[33mDRY RUN — nothing will be removed\033[0m\n'

# ---------------------------------------------------------------------------
# Devcontainer state. These are the inner Docker image store and the VS Code
# server volume. Both are regenerated on the next devcontainer open, but they
# belong to devcontainers used recently — the age gate is what protects them,
# not the fact that their containers are stopped.
if ((DO_DEVCONTAINER)); then
  step "Devcontainer state"
  note "inner Docker image store:"
  mapfile -t dind < <(docker volume ls -q --filter name='dind-var-lib-docker-' 2>/dev/null)
  for v in "${dind[@]}"; do remove_vol "$v"; done
  note "VS Code server + extensions volume:"
  remove_vol vscode
fi

# ---------------------------------------------------------------------------
# Regenerable build/install artifacts: node_modules trees and a cargo registry
# cache. Recreated by the next `npm/pnpm install` / `cargo build`.
if ((DO_CACHES)); then
  step "Regenerable caches"
  mapfile -t nm < <(docker volume ls -q --filter name='node-modules' 2>/dev/null)
  for v in "${nm[@]}"; do remove_vol "$v"; done
  remove_vol cortex_cargo_cache
  note "zero-byte anonymous volumes:"
  while read -r v; do
    [[ -n "$v" ]] || continue
    sz="$(docker system df -v 2>/dev/null | awk -v n="$v" '$1==n {print $NF}' | head -1)"
    [[ "$sz" == "0B" || -z "$sz" ]] && remove_vol "$v"
  done < <(docker volume ls -q --filter 'label=com.docker.volume.anonymous' 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# Orphaned MongoDB data. VERIFIED by inspection to contain WiredTiger data
# (WiredTiger.wt, _mdb_catalog.wt, collection-*.wt). No container references
# them: residue of `docker run mongo` without a named volume, since the mongo
# image declares VOLUME /data/db. This IS data — confirm you do not need it.
if ((DO_MONGO_ORPHANS)); then
  step "Orphaned MongoDB data volumes (DATA)"
  for v in \
    4a280b563dff0506b37ff9c86c355237486ce0f88f8a16e87b255ecfcf35907b \
    942cc9871127d8401978fe3cab86e26b1bdec35d4a8702e1a6808bb2846fd223 \
    49db0a32a8f0589348a3ed7c89ec86951c62db6fdd89e686bc0b1c471bd0c126 \
    7def1fe50ebb72ec78a2ad2bb44efcc8ab20e59d354e5403c97fbf173c2128f5 \
    d50b73833660caf68819f520d72ec7047f770febdada88fbf42356f673df4a12 \
    78382f0a81caf054e26f53ec9aa87fb9808252ee159a0b8a44f6ecec20d56da3 \
    2990a2ff6fef6cb36d78c9cc9132ad8180bfeaf9c65cb491f9f0400c8796de57 ; do
    remove_vol "$v"
  done
fi

# ---------------------------------------------------------------------------
# Orphaned application databases and state. DATA — your call.
if ((DO_ORPHAN_DATA)); then
  step "Orphaned application data (DATA)"
  for v in \
    my-agent_open-webui-data \
    artifact-keeper_dev_postgres_data \
    wapp-assist_postgres_data \
    repuestos-ya_db_data \
    my-agent_signal-cli-data \
    my-agent_zeroclaw-data \
    my-agent_zeroclaw-workspace \
    my-agent_zeroclaw-memory \
    my-agent_zeroclaw-browser \
    my-agent_zeroclaw-workspaces \
    my-agent_zeroclaw-state \
    my-agent_skills-state \
    neuraly_minio_data \
    neuraly_redis_data \
    neuraly_edgedb_data \
    garage_garage_data \
    workspace_meili_data ; do
    remove_vol "$v"
  done
fi

# ---------------------------------------------------------------------------
AFTER="$(avail_bytes)"
((DRY_RUN)) || printf '\n\033[1mFree before: %s   Free after: %s   Reclaimed: %s\033[0m\n' \
  "$(numfmt --to=iec "$BEFORE")" "$(numfmt --to=iec "$AFTER")" \
  "$(numfmt --to=iec $(( AFTER - BEFORE )))"
df -h /
