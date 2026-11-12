#!/usr/bin/env python3
"""Ensure the inotify tag reaches the dynamically included system role."""

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
PLAYBOOK = ROOT / "ansible/local.yml"
SYSTEM_TASKS = ROOT / "ansible/roles/system/tasks/main.yml"
INOTIFY_TASKS = ROOT / "ansible/roles/system/tasks/inotify.yml"


class InotifyTagRoutingTest(unittest.TestCase):
    def test_outer_role_include_exposes_inotify_without_applying_it_to_all_tasks(self):
        play = yaml.safe_load(PLAYBOOK.read_text())[0]
        include = next(
            task for task in play["tasks"]
            if task.get("name") == "Manage system packages and shell setup"
        )
        include_role = include["ansible.builtin.include_role"]

        self.assertIn("inotify", include["tags"])
        self.assertNotIn("inotify", include_role["apply"]["tags"])

    def test_inotify_tasks_keep_their_own_tag(self):
        system_tasks = yaml.safe_load(SYSTEM_TASKS.read_text())
        include = next(
            task for task in system_tasks
            if task.get("name") == "Include inotify instance limit tasks"
        )
        self.assertIn("inotify", include["tags"])

        inotify_tasks = yaml.safe_load(INOTIFY_TASKS.read_text())
        for task in inotify_tasks:
            self.assertIn("inotify", task["tags"], task.get("name", "unnamed task"))


if __name__ == "__main__":
    unittest.main()
