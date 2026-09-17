#!/usr/bin/env bash
# Managed by Ansible (roles/shell_config) -- local edits will be overwritten.
#
# Argument-free wrapper around the journal vacuum so that sudoers can grant an
# exact command with no arguments. sudo-rs (default on Ubuntu 26.04) forbids
# wildcards in command argument positions, and the previous
# "/usr/bin/journalctl --vacuum-size=*" rule is therefore invalid there.
set -Eeuo pipefail

exec /usr/bin/journalctl --vacuum-size=500M
