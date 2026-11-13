#!/usr/bin/env python3
"""Verify the daily cleaner's Docker builder-cache prune policy."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from jinja2 import Environment


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "ansible/roles/shell_config/templates/workstation-auto-clean.sh.j2"


class DockerBuilderPruneTest(unittest.TestCase):
    def render(self, build_cache_age_days):
        return Environment().from_string(TEMPLATE.read_text()).render(
            workstation_cleanup_downloads_max_age_days=90,
            workstation_cleanup_bun_cache_max_age_days=30,
            workstation_cleanup_cargo_target_max_age_days=14,
            workstation_cleanup_go_build_max_age_days=14,
            workstation_cleanup_go_mod_max_age_days=30,
            nix_cleanup_generation_max_age_days=30,
            workstation_cleanup_docker_container_max_age_days=30,
            workstation_cleanup_docker_image_max_age_days=30,
            workstation_cleanup_docker_network_max_age_days=30,
            workstation_cleanup_docker_build_cache_max_age_days=build_cache_age_days,
            workstation_cleanup_vscode_cache_helper_image="python:3.13-alpine@sha256:1e1f6334529d1fb26a2ef619d7cffb30a7c7d7cc1cc7338ebee283a58d1aeaca",
            workstation_cleanup_vscode_extension_cache_max_age_days=30,
            workstation_cleanup_vscode_server_max_age_days=90,
            workstation_cleanup_vscode_server_keep_latest=5,
            workstation_cleanup_vscode_server_protected_commits=[
                "69047191fc427f2f92828279aae1d90d8eeda7ab"
            ],
        )

    def test_prunes_all_unused_builder_cache(self):
        rendered = self.render(30)

        self.assertIn('docker builder prune -af --filter "until=720h"', rendered)

    def test_preserves_configured_last_use_age_window(self):
        rendered = self.render(45)

        self.assertIn('docker builder prune -af --filter "until=1080h"', rendered)
        self.assertIn("builder-cache `until` uses last-use age", rendered)

    def test_rendered_cleanup_script_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n"],
            input=self.render(30),
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_vscode_pruning_protects_server_commit_used_by_running_container(self):
        rendered = self.render(30)

        self.assertIn('docker ps --filter volume=vscode -q', rendered)
        self.assertIn('docker top "$running_container"', rendered)
        self.assertIn('--require-protected-commit --apply', rendered)

        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            home = temp / "home"
            bin_dir = temp / "bin"
            home.mkdir()
            bin_dir.mkdir()
            (home / "workspaces").mkdir()
            helper = home / ".local/bin/workstation-vscode-cache-prune.py"
            helper.parent.mkdir(parents=True)
            helper.write_text("# test helper placeholder\n")
            invocation = temp / "docker-invocation"
            active_commit = "f" * 40
            docker = bin_dir / "docker"
            docker.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  volume) exit 0 ;;\n"
                "  ps) echo running-container; exit 0 ;;\n"
                f"  top) echo '/vscode/vscode-server/bin/linux-x64/{active_commit}/node'; exit 0 ;;\n"
                "  image) exit 0 ;;\n"
                "  container) exit 0 ;;\n"
                "  run) printf '%s\\n' \"$*\" >> \"$DOCKER_INVOCATION\"; exit 0 ;;\n"
                "  *) exit 0 ;;\n"
                "esac\n"
            )
            docker.chmod(0o755)
            for command in ("uv", "direnv", "nix-collect-garbage", "flatpak", "sudo"):
                stub = bin_dir / command
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)

            env = os.environ | {
                "HOME": str(home),
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "DOCKER_INVOCATION": str(invocation),
            }
            result = subprocess.run(
                ["bash", "-c", rendered],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(invocation.exists())
            self.assertIn(f"--protect-commit {active_commit}", invocation.read_text())

    def test_vscode_pruning_protects_commits_referenced_by_workspace_mcp_config(self):
        rendered = self.render(30)
        commit = "261c84cb1eddf11235f9e2c921425e9663fbe556"

        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            home = temp / "home"
            bin_dir = temp / "bin"
            config = home / "workspaces/main-dagster/.vscode/mcp.json"
            home.mkdir()
            bin_dir.mkdir()
            (home / "workspaces").mkdir()
            helper = home / ".local/bin/workstation-vscode-cache-prune.py"
            helper.parent.mkdir(parents=True)
            helper.write_text("# test helper placeholder\n")
            config.parent.mkdir(parents=True)
            config.write_text(
                '{"command":"/vscode/vscode-server/bin/linux-x64/' + commit + '/node"}'
            )
            docker = bin_dir / "docker"
            invocation = temp / "docker-invocation"
            docker.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  volume|image) exit 0 ;;\n"
                "  ps|container) exit 0 ;;\n"
                "  run) printf '%s\\n' \"$*\" >> \"$DOCKER_INVOCATION\"; exit 0 ;;\n"
                "  *) exit 0 ;;\n"
                "esac\n"
            )
            docker.chmod(0o755)
            for command in ("uv", "direnv", "nix-collect-garbage", "flatpak", "sudo"):
                stub = bin_dir / command
                stub.write_text("#!/bin/sh\nexit 0\n")
                stub.chmod(0o755)

            env = os.environ | {
                "HOME": str(home),
                "PATH": f"{bin_dir}:/usr/bin:/bin",
                "DOCKER_INVOCATION": str(invocation),
            }
            result = subprocess.run(
                ["bash", "-c", rendered],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(invocation.exists())
            self.assertIn(f"--protect-commit {commit}", invocation.read_text())
            self.assertIn(
                "--protect-commit 69047191fc427f2f92828279aae1d90d8eeda7ab",
                invocation.read_text(),
            )


if __name__ == "__main__":
    unittest.main()
