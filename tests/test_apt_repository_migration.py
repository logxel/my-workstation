#!/usr/bin/env python3
"""Exercise real Ansible migration tasks against disposable source/key directories."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS = ROOT / "ansible/roles/apt_repositories/tasks"
ROLE = TASKS.parent


def signing_key(base):
    home = base / "gnupg"
    home.mkdir(mode=0o700)
    subprocess.run(["gpg", "--homedir", str(home), "--batch", "--passphrase", "", "--quick-generate-key", "Fixture <fixture@example.invalid>", "ed25519", "sign", "1d"], check=True, capture_output=True)
    result = subprocess.run(["gpg", "--homedir", str(home), "--batch", "--armor", "--export"], check=True, capture_output=True)
    key = base / "fixture.asc"
    key.write_bytes(result.stdout)
    return key


class RepositoryMigrationTest(unittest.TestCase):
    def test_replacements_and_failed_key_preserve_legacy_sources(self):
        with tempfile.TemporaryDirectory(prefix="workstation-repo-test-") as tmp:
            base = Path(tmp)
            sources = base / "sources"
            sources.mkdir()
            keys = base / "keys"
            keys.mkdir()
            for name in ("docker.list", "brave-browser-release.list", "git-core-ubuntu-ppa-noble.list"):
                (sources / name).write_text("legacy\n")

            # Only redirect paths and ownership; retain task logic and tags.
            for name in ("render_source.yml", "cleanup.yml"):
                text = (TASKS / name).read_text()
                text = text.replace("/etc/apt/sources.list.d", str(sources))
                text = text.replace("/etc/apt/keyrings", str(keys))
                text = text.replace("owner: root", f"owner: {os.getuid()}")
                text = text.replace("group: root", f"group: {os.getgid()}")
                (base / name).write_text(text)

            def render(name, key, tags):
                return {
                    "name": "Render " + name,
                    "ansible.builtin.include_tasks": {"file": str(base / "render_source.yml"), "apply": {"tags": tags}},
                    "vars": {"apt_source_name": name, "apt_source_uris": "https://example.invalid", "apt_source_suites": "noble", "apt_source_components": "main", "apt_source_keyring": str(key)},
                    "tags": tags,
                }

            def cleanup(tags):
                return {"ansible.builtin.include_tasks": str(base / "cleanup.yml"), "tags": tags}

            def run(tasks, tags):
                play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
                         "vars": {"role_path": str(ROLE), "apt_repositories_validated_downloads": {
                             str(keys / "missing.asc"): True, str(keys / "invalid.asc"): True,
                             str(base / "fixture.asc"): True}}, "tasks": tasks}]
                path = base / "play.yml"
                path.write_text(yaml.safe_dump(play))
                subprocess.run(["ansible-playbook", "-i", "localhost,", str(path), "--tags", tags], check=True, capture_output=True, text=True)

            # A failed replacement must leave the legacy file untouched.
            run([render("docker", keys / "missing.asc", ["docker"]), cleanup(["docker"])], "docker")
            self.assertTrue((sources / "docker.list").exists())
            self.assertFalse((sources / "docker.sources").exists())
            run([render("docker", keys / "missing.asc", ["packages"]), cleanup(["packages"])], "packages")
            self.assertTrue((sources / "docker.list").exists())
            self.assertTrue((sources / "git-core-ubuntu-ppa-noble.list").exists())

            invalid = keys / "invalid.asc"
            invalid.write_text("not an OpenPGP key\n")
            run([render("docker", invalid, ["docker"]), cleanup(["docker"])], "docker")
            self.assertTrue((sources / "docker.list").exists())
            self.assertFalse((sources / "docker.sources").exists())

            key = signing_key(base)
            run([render("brave-browser-release", key, ["brave"]), cleanup(["brave"])], "brave")
            self.assertFalse((sources / "brave-browser-release.list").exists())
            self.assertTrue((sources / "brave-browser-release.sources").exists())
            self.assertTrue((sources / "docker.list").exists())

            # The packages-scoped Git migration must discover and remove legacy files.
            run([render("git-core-ppa", key, ["packages"]), cleanup(["packages"])], "packages")
            self.assertFalse((sources / "git-core-ubuntu-ppa-noble.list").exists())
            self.assertTrue((sources / "git-core-ppa.sources").exists())
            self.assertTrue((sources / "docker.list").exists())

    def test_role_tag_scope_and_invalid_download(self):
        with tempfile.TemporaryDirectory(prefix="workstation-role-test-") as tmp:
            base = Path(tmp)
            sources = base / "sources"
            sources.mkdir()
            keys = base / "keys"
            keys.mkdir()
            roles = base / "roles"
            shutil.copytree(ROLE, roles / "apt_repositories")
            role = roles / "apt_repositories"
            for path in (role / "tasks").glob("*.yml"):
                text = path.read_text().replace("/etc/apt/sources.list.d", str(sources)).replace("/etc/apt/keyrings", str(keys))
                text = text.replace("owner: root", f"owner: {os.getuid()}").replace("group: root", f"group: {os.getgid()}")
                path.write_text(text)
            main = role / "tasks/main.yml"
            text = main.read_text()
            # Substitute both APT operations before executing the role: tests must
            # never install packages or refresh the real system's package cache.
            install_apt = "  ansible.builtin.apt:\n    name: gnupg\n    state: present\n    update_cache: false"
            cache_apt = "      ansible.builtin.apt:\n        update_cache: true"
            self.assertIn(install_apt, text)
            self.assertIn(cache_apt, text)
            text = text.replace(install_apt, '  ansible.builtin.debug:\n    msg: "MOCK_GNUPG_INSTALL"')
            text = text.replace(cache_apt, '      ansible.builtin.debug:\n        msg: "MOCK_APT_CACHE_REFRESH"')
            key = signing_key(base)
            text = text.replace("https://download.docker.com/linux/ubuntu/gpg", key.as_uri())
            main.write_text(text)
            (sources / "docker.list").write_text("legacy docker\n")
            (sources / "brave-browser-release.list").write_text("legacy brave\n")
            (keys / "hluk-copyq.gpg").write_text("preserve\n")
            original_play = yaml.safe_load((ROOT / "ansible/local.yml").read_text())[0]
            include = next(t for t in original_play["tasks"] if t["name"] == "Manage APT repositories")
            play = [{"hosts": "localhost", "connection": "local", "gather_facts": False,
                     "vars": {"common_run_role_apt_repositories": True, "common_enable_docker": True,
                              "common_enable_brave": True, "common_enable_vscode": False, "common_enable_edge": False,
                              "common_enable_dev_tools": False, "common_enable_warp_terminal": False,
                              "common_selective_feature_run": True, "common_enable_git_credential_oauth": False,
                              "common_deb_arch": "amd64", "common_ubuntu_codename": "noble",
                              "supported_distributions": ["Ubuntu"], "ansible_facts": {"distribution": "Ubuntu"}},
                     "tasks": [include]}]
            playbook = base / "play.yml"
            playbook.write_text(yaml.safe_dump(play))
            env = dict(os.environ, ANSIBLE_ROLES_PATH=str(roles))
            def run(tag="docker"):
                return subprocess.run(["ansible-playbook", "-i", "localhost,", str(playbook), "--tags", tag], check=True, capture_output=True, text=True, env=env).stdout
            output = run()
            self.assertLess(output.index("MOCK_GNUPG_INSTALL"), output.index("Download the repository signing key"))
            self.assertLess(output.index("Download the repository signing key"), output.index("MOCK_APT_CACHE_REFRESH"))
            self.assertTrue((sources / "docker.sources").exists())
            self.assertFalse((sources / "docker.list").exists())
            self.assertTrue((sources / "brave-browser-release.list").exists())
            self.assertFalse((sources / "brave-browser-release.sources").exists())
            self.assertTrue((keys / "hluk-copyq.gpg").exists())
            before = (keys / "docker.asc").read_bytes()
            (sources / "docker.list").write_text("legacy docker\n")
            key.write_text("not a key\n")
            run()
            self.assertEqual((keys / "docker.asc").read_bytes(), before)
            self.assertTrue((sources / "docker.list").exists())
            (sources / "hluk-copyq.list").write_text("legacy copyq\n")
            run("copyq")
            self.assertFalse((sources / "hluk-copyq.list").exists())
            self.assertTrue((keys / "hluk-copyq.gpg").exists())
            self.assertTrue((sources / "docker.list").exists())
            # No unrelated feature is enabled for these tag-routing checks.
            play[0]["vars"]["common_enable_brave"] = False
            playbook.write_text(yaml.safe_dump(play))
            for tag in ("vscode", "edge", "brave", "docker", "dev-tools", "nodejs", "warp-terminal", "git", "repos", "packages", "system"):
                with self.subTest(tag=tag):
                    output = run(tag)
                    self.assertIn("MOCK_GNUPG_INSTALL", output)
                    self.assertIn("MOCK_APT_CACHE_REFRESH", output)


class SigningKeyTest(unittest.TestCase):
    def test_format_fingerprint_and_expiry(self):
        with tempfile.TemporaryDirectory(prefix="workstation-key-test-") as tmp:
            base = Path(tmp)
            key = signing_key(base)
            validator = ROLE / "files/validate_apt_key.py"
            def check(path, destination, fingerprint=""):
                return subprocess.run(["python3", str(validator), str(path), destination, fingerprint], capture_output=True)
            self.assertEqual(check(key, "key.asc").returncode, 0)
            self.assertNotEqual(check(key, "key.gpg").returncode, 0)
            self.assertNotEqual(check(key, "key.asc", "0" * 40).returncode, 0)
            home = base / "gnupg"
            subprocess.run(["gpg", "--homedir", str(home), "--batch", "--passphrase", "", "--quick-generate-key", "Second <second@example.invalid>", "ed25519", "sign", "1d"], check=True, capture_output=True)
            listing = subprocess.run(["gpg", "--homedir", str(home), "--batch", "--with-colons", "--list-keys"], check=True, capture_output=True, text=True).stdout
            fingerprints = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")]
            bundle = base / "bundle.asc"
            bundle.write_bytes(subprocess.run(["gpg", "--homedir", str(home), "--batch", "--armor", "--export"], check=True, capture_output=True).stdout)
            self.assertEqual(len(fingerprints), 2)
            self.assertNotEqual(check(bundle, "key.asc").returncode, 0)
            self.assertNotEqual(check(bundle, "key.asc", fingerprints[0]).returncode, 0)
            self.assertEqual(check(bundle, "key.asc", ",".join(fingerprints)).returncode, 0)
            home = base / "old-gnupg"
            home.mkdir(mode=0o700)
            subprocess.run(["gpg", "--homedir", str(home), "--batch", "--faked-system-time", "20200101T000000", "--passphrase", "", "--quick-generate-key", "Old <old@example.invalid>", "ed25519", "sign", "1d"], check=True, capture_output=True)
            expired = base / "expired.asc"
            expired.write_bytes(subprocess.run(["gpg", "--homedir", str(home), "--batch", "--armor", "--export"], check=True, capture_output=True).stdout)
            self.assertNotEqual(check(expired, "key.asc").returncode, 0)

class UpgradeBackupTest(unittest.TestCase):
    def test_backup_with_and_without_legacy_sources_list(self):
        script = (ROOT / "scripts/prep-ubuntu-26.sh").read_text()
        snippet = script.split("BACKUP_PATHS=(", 1)[1].split('echo "  backup:', 1)[0]
        with tempfile.TemporaryDirectory(prefix="workstation-backup-test-") as tmp:
            base = Path(tmp)
            apt = base / "apt"
            (apt / "sources.list.d").mkdir(parents=True)
            (base / "update-manager").mkdir()
            (apt / "sources.list.d" / "ubuntu.sources").write_text("fixture\n")
            snippet = "BACKUP_PATHS=(" + snippet.replace("/etc/apt", str(apt)).replace("/etc/update-manager", str(base / "update-manager"))
            for legacy_exists in (False, True):
                if legacy_exists:
                    (apt / "sources.list").write_text("legacy\n")
                archive = base / "backup.tar.gz"
                command = 'sudo() { "$@"; }\nBACKUP="$1"\n' + snippet
                subprocess.run(["bash", "-eu", "-c", command, "test", str(archive)], check=True, capture_output=True)
                with tarfile.open(archive) as backup:
                    names = backup.getnames()
                self.assertTrue(any(name.endswith("sources.list.d/ubuntu.sources") for name in names))
                self.assertEqual(any(name.endswith("/sources.list") for name in names), legacy_exists)


if __name__ == "__main__":
    unittest.main()
