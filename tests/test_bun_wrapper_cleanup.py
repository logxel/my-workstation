#!/usr/bin/env python3
"""Exercise the legacy Bun shim cleanup against disposable home directories."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS = ROOT / "ansible/roles/shell_config/tasks/cleanup_legacy_bun_wrappers.yml"


def without_become(source: Path, destination: Path) -> Path:
    """Drop privilege escalation so the tasks run as the test user."""
    kept = [
        line
        for line in source.read_text().splitlines(keepends=True)
        if not line.lstrip().startswith(("become: true", 'become_user: "{{ local_user }}"'))
    ]
    destination.write_text("".join(kept))
    return destination


class BunWrapperCleanupTest(unittest.TestCase):
    def test_removes_only_shims_that_forward_to_bun(self):
        with tempfile.TemporaryDirectory(prefix="workstation-bun-cleanup-test-") as tmp:
            base = Path(tmp)
            tasks_file = without_become(TASKS, base / "cleanup.yml")

            # Case A: legacy npm wrapper plus a node shim that execs bun.
            shim_home = base / "shim-home"
            shim_bin = shim_home / ".local" / "bin"
            shim_bin.mkdir(parents=True)
            (shim_bin / "npm").write_text('#!/usr/bin/env bash\nexec "$HOME/.bun/bin/bun" "$@"\n')
            (shim_bin / "node").write_text('#!/bin/sh\nexec bun "$@"\n')

            # Case B: a real-looking node binary that never mentions bun.
            real_home = base / "real-home"
            real_bin = real_home / ".local" / "bin"
            real_bin.mkdir(parents=True)
            (real_bin / "node").write_bytes(b"\x7fELF" + b"node\x00" * 2048)

            def cleanup(home):
                return {
                    "name": f"Run legacy cleanup for {home.name}",
                    "ansible.builtin.include_tasks": str(tasks_file),
                    "vars": {"local_home": str(home), "local_user": "nobody"},
                }

            def absent(path):
                return f"not ({json.dumps(path)} is exists)"

            def present(path):
                return f"{json.dumps(path)} is exists"

            tasks = [
                cleanup(shim_home),
                {
                    "name": "Assert the Bun shims are gone",
                    "ansible.builtin.assert": {
                        "that": [
                            absent(str(shim_bin / "npm")),
                            absent(str(shim_bin / "node")),
                        ],
                        "fail_msg": "Legacy Bun wrappers and the node shim must be removed",
                    },
                },
                cleanup(real_home),
                {
                    "name": "Assert a real node binary is preserved",
                    "ansible.builtin.assert": {
                        "that": [present(str(real_bin / "node"))],
                        "fail_msg": "A node binary that does not exec bun must be preserved",
                    },
                },
                cleanup(shim_home),
                {
                    "name": "Assert the cleanup is idempotent",
                    "ansible.builtin.assert": {
                        "that": [absent(str(shim_bin / "node"))],
                        "fail_msg": "A second run must not recreate or fail on missing shims",
                    },
                },
            ]

            play = [{
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
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
