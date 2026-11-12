#!/usr/bin/env python3
"""Exercise the swap ownership gate against a disposable swap path."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DISCOVERY = ROOT / "ansible/roles/swap/tasks/discovery.yml"


class SwapOwnershipTest(unittest.TestCase):
    def test_legacy_defaults_and_marker_ownership(self):
        with tempfile.TemporaryDirectory(prefix="workstation-swap-test-") as tmp:
            base = Path(tmp)
            swap_file = base / "swapfile"
            swap_file.write_text("fixture\n")
            # A marker that is not root-owned must never grant ownership.
            (base / "swapfile.my-workstation-managed").write_text(f"{swap_file}\n")

            managed = [str(swap_file), str(swap_file) + ".1"]
            cases = [
                ("legacy defaults cover the managed paths", managed, managed),
                ("no legacy list and a non-root marker", [], []),
                ("pre-marker defaults do not cover a custom path", ["/swapfile", "/swapfile.1"], []),
            ]

            tasks = []
            for label, legacy, expected in cases:
                tasks.append({
                    "name": f"Discover swap state with {label}",
                    "ansible.builtin.include_tasks": str(DISCOVERY),
                    "vars": {"swap_legacy_managed_paths": legacy},
                })
                tasks.append({
                    "name": f"Assert ownership with {label}",
                    "ansible.builtin.assert": {
                        "that": [
                            f"swap_owned_paths | sort == {json.dumps(sorted(expected))}",
                        ],
                        "fail_msg": (
                            f"{label}: expected owned paths {expected}; "
                            "got {{ swap_owned_paths }} (legacy {{ swap_legacy_owned_paths }})"
                        ),
                    },
                })

            play = [{
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
                "vars": {"swap_file_path": str(swap_file)},
                "tasks": tasks,
            }]
            path = base / "play.yml"
            path.write_text(yaml.safe_dump(play))

            result = subprocess.run(
                ["ansible-playbook", "-i", "localhost,", str(path)],
                cwd=str(ROOT),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
