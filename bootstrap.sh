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