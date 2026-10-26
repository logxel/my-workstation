#!/usr/bin/env bash
#
# prep-ubuntu-26.sh — pre-flight preparation for an eventual Ubuntu 24.04 -> 26.04 LTS upgrade.
#
# Run with:   bash ./scripts/prep-ubuntu-26.sh
#
# Safe to re-run. This does NOT perform the release upgrade: Canonical has not yet
# enabled the 24.04 -> 26.04 path (meta-release-lts still reports Supported: 0 for
# resolute). This only gets the host ready for when that gate opens.
#
# What it does:
#   1. backs up apt + update-manager config (the upgrader rewrites these)
#   2. applies all pending updates (be current before a dist-upgrade)
#   3. removes stray/empty third-party source files
#   4. reclaims disk space (apt cache, journal, snap revisions, orphaned configs)
#   5. reports free space and whether a reboot is pending

set -Eeuo pipefail

STAMP="$(date +%F-%H%M)"
# Create the destination as the invoking user with mode 0600 before sudo tar
# writes it, so APT source credentials are not exposed to other local users.
BACKUP="$(mktemp "$HOME/apt-config-backup-$STAMP.XXXXXX.tar.gz")"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

trap 'printf "\n\033[31mFAILED: line %s, exit %s\033[0m\n" "$LINENO" "$?" >&2' ERR

# Ask for the sudo password once up front instead of on every command.
sudo -v

step "1/5  Backing up apt + update-manager configuration"
sudo tar czf "$BACKUP" \
  /etc/apt/sources.list /etc/apt/sources.list.d /etc/update-manager
echo "  backup: $BACKUP"

step "2/5  Applying pending package updates"
sudo apt update
sudo apt full-upgrade -y

step "3/5  Removing stray / empty third-party source files"
sudo rm -f /etc/apt/sources.list.d/signal-desktop.sources \
           /etc/apt/sources.list.d/ubuntu.sources.curtin.orig

step "4/5  Reclaiming disk space"
sudo apt-get clean
sudo apt-get autoremove --purge -y
sudo /usr/local/sbin/workstation-journal-vacuum
sudo snap set system refresh.retain=2

# Collect disabled (old) snap revisions without using a pipeline, so that
# `set -o pipefail` cannot turn an early-exiting consumer into a false failure.
mapfile -t DISABLED_SNAPS < <(snap list --all 2>/dev/null | awk '/disabled/{print $1" "$3}')
if ((${#DISABLED_SNAPS[@]} > 0)); then
  for entry in "${DISABLED_SNAPS[@]}"; do
    name="${entry%% *}"
    rev="${entry##* }"
    echo "  removing $name (revision $rev)"
    sudo snap remove "$name" --revision="$rev" || true
  done
else
  echo "  no disabled snap revisions"
fi

step "5/5  Result"
df -h /
if [[ -e /var/run/reboot-required ]]; then
  echo "REBOOT NEEDED"
else
  echo "no reboot required"
fi

cat <<'EOF'

Done. Next step is to WAIT — do not run `do-release-upgrade -d`.

Check the upgrade gate until it reports Supported: 1 for resolute:
  curl -s https://changelogs.ubuntu.com/meta-release-lts | grep -A5 'Dist: resolute'
EOF
