#!/usr/bin/env python3
"""Exercise the RAM-derived inotify instance formula against fake /proc inputs."""

import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
DERIVE = ROOT / "ansible/roles/system/tasks/inotify_derive.yml"
KNOBS = {
    "inotify_instances_floor": 1024,
    "inotify_instances_ceiling": 8192,
    "inotify_instances_per_gib": 256,
}

# (memtotal_mb, current instances, expected target, expected raise decision)
CASES = [
    (2048, 128, 1024, True),  # floor: 2 GiB * 256 = 512 -> 1024
    (4096, 128, 1024, True),  # 4 GiB * 256 = 1024
    (8192, 128, 2048, True),
    (15870, 128, 3840, True),  # 15.49 GiB rounds down to 15
    (15974, 128, 4096, True),  # 15.60 GiB rounds up to 16
    (16384, 2047, 4096, True),  # one instance below half the target
    (16384, 2048, 4096, False),  # exactly half the target: leave it alone
    (30443, 3839, 7680, True),  # 29.73 GiB -> 30 GiB, the deployed host value
    (30443, 3840, 7680, False),  # already at half of the deployed target
    (65536, 128, 8192, True),  # ceiling: 64 GiB * 256 = 16384 -> 8192
    (131072, 128, 8192, True),  # above the ceiling stays clamped
    (2048, 512, 1024, False),  # floor target at exactly half
]


class InotifyInstancesTest(unittest.TestCase):
    def test_ram_derived_target_and_half_threshold(self):
        with tempfile.TemporaryDirectory(prefix="workstation-inotify-test-") as tmp:
            base = Path(tmp)
            tasks = []
            for index, (mem_mb, current, target, raise_limit) in enumerate(CASES):
                proc = base / f"max_user_instances.{index}"
                proc.write_text(f"{current}\n")
                label = f"memtotal_mb={mem_mb} current={current}"
                tasks.append({
                    "name": f"Derive the inotify limit for {label}",
                    "ansible.builtin.include_tasks": str(DERIVE),
                    "vars": {
                        "inotify_instances_proc_path": str(proc),
                        "inotify_instances_memtotal_mb": mem_mb,
                    },
                })
                tasks.append({
                    "name": f"Assert the inotify limit for {label}",
                    "ansible.builtin.assert": {
                        "that": [
                            f"system_inotify_instances_target | int == {target}",
                            f"(system_inotify_instances_apply | bool) == {'true' if raise_limit else 'false'}",
                        ],
                        "fail_msg": (
                            f"{label}: expected target {target} and raise decision {raise_limit}; "
                            "got {{ system_inotify_instances_target }} and {{ system_inotify_instances_apply }}"
                        ),
                    },
                })

            play = [{
                "hosts": "localhost",
                "connection": "local",
                "gather_facts": False,
                "vars": KNOBS,
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
