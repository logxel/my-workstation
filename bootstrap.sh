#!/usr/bin/env bash
set -Eeuo pipefail

# This bootstrap is safe to rerun: it only installs missing prerequisites,
# clones the repository if needed, and then hands off the actual provisioning to
# the idempotent Ansible playbook.

REPO_DIR="${HOME}/my-workstation"
DEFAULT_REPO_URL="https://github.com/logxel/my-workstation.git"
REPO_URL="${DOTFILES_REPO_URL:-${DEFAULT_REPO_URL}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY_FEATURES=""
ANSIBLE_ARGS=()

while (($# > 0)); do
  case "$1" in
    --only-feature|--only-features)
      if (($# < 2)); then
        echo "Missing value for $1" >&2
        exit 2
      fi
      ONLY_FEATURES="$2"
      shift 2
      ;;
    --only-feature=*|--only-features=*)
      ONLY_FEATURES="${1#*=}"
      shift
      ;;
    *)
      ANSIBLE_ARGS+=("$1")
      shift
      ;;
  esac
done

sudo -v

while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "${SUDO_KEEPALIVE_PID}"' EXIT

missing_packages=()

command -v git >/dev/null 2>&1 || missing_packages+=(git)
command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
command -v ansible-playbook >/dev/null 2>&1 || missing_packages+=(ansible)

if (( ${#missing_packages[@]} > 0 )); then
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
fi

# Ansible runs the playbook on this host's python3. ansible-core only supports
# Python 3.14 from 2.20 onward, and older versions fail with an obscure
# traceback from inside a task rather than a usable error. Ubuntu 26.04 ships
# python3 3.14, so a controller left on noble's 2.16.3 breaks the run.
#
# The floor is applied only when the controller Python is 3.14+, because 2.16.3
# is perfectly fine against 24.04's own Python 3.12. Note the system package on
# 26.04 is ansible-core 2.20.1, so the floor here must be 2.20 and not the
# stricter 2.21 used by the devcontainer image.
python3_minor() {
  python3 -c 'import sys; print("{}.{}".format(*sys.version_info[:2]))' 2>/dev/null || true
}

ansible_core_version() {
  ansible-playbook --version 2>/dev/null \
    | sed -n 's/.*\[core \([0-9][0-9.]*\)\].*/\1/p' | head -1 || true
}

version_ge() { # version_ge <have> <want>
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

PYTHON_MINOR="$(python3_minor)"
ANSIBLE_CORE="$(ansible_core_version)"

if [[ -n "${PYTHON_MINOR}" && -n "${ANSIBLE_CORE}" ]] \
  && version_ge "${PYTHON_MINOR}" "3.14" \
  && ! version_ge "${ANSIBLE_CORE}" "2.20"; then
  cat >&2 <<EOF
ansible-core ${ANSIBLE_CORE} cannot run on Python ${PYTHON_MINOR}.

ansible-core gained Python 3.14 support in 2.20. This host's python3 is
${PYTHON_MINOR}, so the controller must be 2.20 or newer; 2.19 and earlier fail
partway into the first task instead of reporting the real cause.

Fix with either:
  sudo apt-get install --only-upgrade ansible-core
  python3 -m pip install --user --break-system-packages 'ansible-core>=2.21'
EOF
  exit 1
fi

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  if [[ -d "${SCRIPT_DIR}/.git" && "${SCRIPT_DIR}" == "${REPO_DIR}" ]]; then
    echo "El repositorio ya está disponible en ${REPO_DIR}, omitiendo clonación."
  else
    git clone "${REPO_URL}" "${REPO_DIR}"
  fi
else
  echo "El repositorio ya existe en ${REPO_DIR}, omitiendo clonación."
  git -C "${REPO_DIR}" pull --ff-only
fi

cd "${REPO_DIR}"

if [[ -n "${ONLY_FEATURES}" ]]; then
  ANSIBLE_ARGS+=(--extra-vars "dotfiles_only_features=${ONLY_FEATURES}")
fi

ansible-playbook ansible/local.yml "${ANSIBLE_ARGS[@]}"