#!/usr/bin/env python3
"""Exercise the installer wrapper with a harmless local stand-in."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS = ROOT / "ansible/roles/system/tasks/clipboard_history.yml"


class RingboardInstallerTest(unittest.TestCase):
    def test_isolation_and_cleanup_on_success_and_failure(self):
        original_tasks = yaml.safe_load(TASKS.read_text())
        for exit_code in (0, 1):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                home = base / "home"
                home.mkdir()
                sentinel = base / "unrelated"
                sentinel.write_text("keep")
                result = base / "result"
                script = base / "stand-in.sh"
                script.write_text(
                    '#!/bin/sh\n'
                    f'printf "%s\\n" "$PWD" "$HOME" "$CARGO_HOME" > "{result}"\n'
                    'touch artifact\n'
                    f'exit {exit_code}\n'
                )
                tasks = yaml.safe_load(yaml.safe_dump([
                    task for task in original_tasks if task.get("name") in (
                        "Create temporary directory for Ringboard installer",
                        "Install Ringboard with Iced GUI via official install script",
                    )
                ]))
                download = tasks[1]["block"][0]
                download.pop("ansible.builtin.get_url")
                download["ansible.builtin.copy"] = {
                    "src": str(script),
                    "dest": "{{ system_ringboard_install_temp.path }}/install-ringboard.sh",
                    "mode": "0755",
                }
                play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
                         "vars": {"local_home": str(home), "clipboard_history_branch": "test"},
                         "tasks": tasks}]
                playbook = base / "play.yml"
                playbook.write_text(yaml.safe_dump(play))
                env = dict(os.environ, CARGO_HOME=str(base / "wrong-cargo"))
                run = subprocess.run(["ansible-playbook", "-i", "localhost,", str(playbook)],
                                     cwd=base, env=env, capture_output=True, text=True)
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                workdir, actual_home, cargo_home = result.read_text().splitlines()
                self.assertNotEqual(workdir, str(base))
                self.assertFalse(Path(workdir).exists())
                self.assertEqual(actual_home, str(home))
                self.assertEqual(cargo_home, str(home / ".cargo"))
                self.assertFalse((base / "artifact").exists())
                self.assertEqual(sentinel.read_text(), "keep")
                if exit_code:
                    self.assertIn("Could not install Ringboard", run.stdout)


if __name__ == "__main__":
    unittest.main()
