#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_NAME="farintervpn-final"

invoking_user() {
  printf '%s\n' "${SUDO_USER:-${USER:-$(id -un)}}"
}

invoking_home() {
  local user_name
  local home_path

  user_name="$(invoking_user)"
  home_path="$(getent passwd "$user_name" | cut -d: -f6)"

  if [[ -z "$home_path" ]]; then
    printf 'Unable to determine home directory for %s\n' "$user_name" >&2
    exit 1
  fi

  printf '%s\n' "$home_path"
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/nm-openvpn-helper.sh install [nmconnection-path]
  ./scripts/nm-openvpn-helper.sh up <connection-name>
  ./scripts/nm-openvpn-helper.sh down <connection-name>
  ./scripts/nm-openvpn-helper.sh show <connection-name>

Commands:
  install   Copy a native .nmconnection profile into NetworkManager exactly as
            written in the file.
  up        Bring the VPN connection up.
  down      Bring the VPN connection down.
  show      Display the effective NetworkManager settings for the connection.

Notes:
  - This helper targets the native NetworkManager keyfile workflow.
  - The host still needs the distro openvpn package because
    network-manager-openvpn depends on it.
  - The install command treats the .nmconnection file as authoritative and does
    not rewrite the loaded profile.
EOF
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
}

prompt_profile_path() {
  local profile_path

  read -r -e -p "Path to .nmconnection profile: " profile_path
  profile_path="${profile_path/#\~/$HOME}"
  printf '%s\n' "$profile_path"
}

connection_exists() {
  local connection_name="$1"

  nmcli -t -f NAME connection show | grep -Fxq "$connection_name"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
  fi
}

profile_basename() {
  local profile_path="$1"

  basename "$profile_path" .nmconnection
}

install_connection() {
  local profile_path="$1"
  local install_path
  local connection_name

  require_root install "$profile_path"

  if [[ ! -f "$profile_path" ]]; then
    printf 'File not found: %s\n' "$profile_path" >&2
    exit 1
  fi

  connection_name="$(profile_basename "$profile_path")"
  install_path="/etc/NetworkManager/system-connections/${connection_name}.nmconnection"

  install -m 0600 "$profile_path" "$install_path"
  nmcli connection load "$install_path" >/dev/null
  show_connection "$connection_name"
}

show_connection() {
  local connection_name="$1"

  nmcli connection show "$connection_name" | sed -n '/^ipv4.method:/,/^proxy.pac-script:/p'
}

main() {
  local command_name="${1:-}"
  local connection_name

  require_command nmcli

  case "$command_name" in
    install)
      install_connection "${2:-$(prompt_profile_path)}"
      ;;
    up)
      connection_name="${2:-$DEFAULT_NAME}"
      nmcli connection up id "$connection_name"
      ;;
    down)
      connection_name="${2:-$DEFAULT_NAME}"
      nmcli connection down id "$connection_name"
      ;;
    show)
      connection_name="${2:-$DEFAULT_NAME}"
      show_connection "$connection_name"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"