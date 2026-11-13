#!/usr/bin/env python3
"""Verify age-based VS Code cache pruning and retention safeguards."""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "ansible/roles/shell_config/files/workstation-vscode-cache-prune.py"
PROTECTED = "261c84cb1eddf11235f9e2c921425e9663fbe556"
OLD_A = "a" * 40
OLD_B = "b" * 40
OLD_C = "c" * 40
RECENT_D = "d" * 40
RECENT_E = "e" * 40


def set_tree_mtime(path: Path, mtime: float) -> None:
    for child in sorted(path.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        os.utime(child, (mtime, mtime), follow_symlinks=False)
    os.utime(path, (mtime, mtime), follow_symlinks=False)


class VSCodeCachePruneTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / "vscode-server"
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_helper(self, *args):
        return subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root",
                str(self.root),
                "--extension-cache-max-age-days",
                "30",
                "--server-max-age-days",
                "30",
                "--keep-latest",
                "2",
                *args,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def add_cache_entry(self, name: str, days_old: int) -> Path:
        entry = self.root / "extensionsCache" / name
        entry.mkdir(parents=True)
        (entry / "payload.vsix").write_bytes(b"cached-extension")
        set_tree_mtime(entry, time.time() - days_old * 86400)
        return entry

    def add_server_build(self, commit: str, days_old: int) -> Path:
        build = self.root / "bin" / "linux-x64" / commit
        build.mkdir(parents=True)
        (build / "node").write_bytes(b"server-binary")
        set_tree_mtime(build, time.time() - days_old * 86400)
        return build

    def test_apply_removes_old_cache_but_keeps_fresh_cache(self):
        old = self.add_cache_entry("extension-old", 60)
        fresh = self.add_cache_entry("extension-fresh", 2)

        result = self.run_helper("--apply")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(old.exists())
        self.assertTrue(fresh.exists())

    def test_apply_keeps_protected_commit_and_two_latest_builds(self):
        protected = self.add_server_build(PROTECTED, 120)
        old_a = self.add_server_build(OLD_A, 110)
        old_b = self.add_server_build(OLD_B, 100)
        old_c = self.add_server_build(OLD_C, 90)
        recent = self.add_server_build(RECENT_D, 2)
        recent_e = self.add_server_build(RECENT_E, 5)

        result = self.run_helper(
            "--protect-commit",
            PROTECTED,
            "--require-protected-commit",
            "--apply",
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(protected.exists())
        self.assertTrue(recent.exists())
        self.assertTrue(recent_e.exists())
        self.assertFalse(old_a.exists())
        self.assertFalse(old_b.exists())
        self.assertFalse(old_c.exists())

    def test_default_dry_run_does_not_remove_candidates(self):
        old = self.add_cache_entry("extension-old", 60)

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(old.exists())
        self.assertIn("would remove:", result.stdout)

    def test_missing_protected_commit_skips_server_pruning(self):
        old = self.add_server_build(OLD_A, 60)

        result = self.run_helper("--require-protected-commit", "--apply")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(old.exists())
        self.assertIn("no MCP server commit could be protected", result.stderr)


if __name__ == "__main__":
    unittest.main()
