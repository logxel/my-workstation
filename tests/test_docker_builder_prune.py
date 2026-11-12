#!/usr/bin/env python3
"""Verify the daily cleaner's Docker builder-cache prune policy."""

import subprocess
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


if __name__ == "__main__":
    unittest.main()
