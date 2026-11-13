#!/usr/bin/env python3
"""Prune aged VS Code Dev Container downloads and server builds."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
import time
from pathlib import Path

COMMIT = re.compile(r"^[0-9a-f]{40}$")


def tree_metadata(path: Path) -> tuple[float, int] | None:
    """Return newest mtime and logical bytes; fail closed on unreadable trees."""
    try:
        root_stat = path.lstat()
    except OSError:
        return None
    if stat.S_ISLNK(root_stat.st_mode):
        return None
    if not stat.S_ISDIR(root_stat.st_mode):
        return root_stat.st_mtime, root_stat.st_size

    newest = root_stat.st_mtime
    total_bytes = root_stat.st_size
    pending = [path]
    while pending:
        current = pending.pop()
        try:
            with os.scandir(current) as entries:
                for entry in entries:
                    entry_stat = entry.stat(follow_symlinks=False)
                    newest = max(newest, entry_stat.st_mtime)
                    total_bytes += entry_stat.st_size
                    if stat.S_ISDIR(entry_stat.st_mode):
                        pending.append(Path(entry.path))
        except OSError:
            return None
    return newest, total_bytes


def remove_candidate(path: Path, size: int, apply: bool) -> bool:
    action = "remove" if apply else "would remove"
    print(f"{action}: {path} ({size / (1024**3):.2f} GiB)")
    if not apply:
        return True
    try:
        candidate_stat = path.lstat()
        if stat.S_ISLNK(candidate_stat.st_mode):
            print(f"refusing symlink: {path}", file=sys.stderr)
            return False
        if stat.S_ISDIR(candidate_stat.st_mode):
            shutil.rmtree(path)
        elif stat.S_ISREG(candidate_stat.st_mode):
            path.unlink()
        else:
            print(f"refusing non-file cache entry: {path}", file=sys.stderr)
            return False
        return True
    except OSError as error:
        print(f"could not remove {path}: {error}", file=sys.stderr)
        return False


def prune_extension_cache(root: Path, cutoff: float, apply: bool) -> int:
    cache = root / "extensionsCache"
    if not cache.is_dir() or cache.is_symlink():
        return 0

    reclaimed = 0
    for candidate in cache.iterdir():
        if candidate.is_symlink():
            continue
        metadata = tree_metadata(candidate)
        if metadata is None:
            print(f"skipping unreadable cache entry: {candidate}", file=sys.stderr)
            continue
        newest, size = metadata
        if newest < cutoff:
            if remove_candidate(candidate, size, apply):
                reclaimed += size
    return reclaimed


def prune_server_builds(
    root: Path,
    cutoff: float,
    keep_latest: int,
    protected: set[str],
    require_protected: bool,
    apply: bool,
) -> int:
    if require_protected and not protected:
        print(
            "skipping server-build pruning: no MCP server commit could be protected",
            file=sys.stderr,
        )
        return 0

    bin_root = root / "bin"
    if not bin_root.is_dir() or bin_root.is_symlink():
        return 0

    reclaimed = 0
    for platform_root in bin_root.iterdir():
        if not platform_root.is_dir() or platform_root.is_symlink():
            continue
        builds: list[tuple[Path, float, int]] = []
        for build in platform_root.iterdir():
            if not build.is_dir() or build.is_symlink() or not COMMIT.fullmatch(build.name):
                continue
            metadata = tree_metadata(build)
            if metadata is None:
                print(f"skipping unreadable server build: {build}", file=sys.stderr)
                continue
            newest, size = metadata
            builds.append((build, newest, size))

        newest_builds = {
            build.name
            for build, _, _ in sorted(builds, key=lambda item: item[1], reverse=True)[
                :keep_latest
            ]
        }
        for build, newest, size in builds:
            if build.name in protected or build.name in newest_builds or newest >= cutoff:
                continue
            if remove_candidate(build, size, apply):
                reclaimed += size
    return reclaimed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("/vscode/vscode-server"))
    parser.add_argument("--extension-cache-max-age-days", type=int, required=True)
    parser.add_argument("--server-max-age-days", type=int, required=True)
    parser.add_argument("--keep-latest", type=int, required=True)
    parser.add_argument("--protect-commit", action="append", default=[])
    parser.add_argument("--require-protected-commit", action="store_true")
    parser.add_argument(
        "--apply", action="store_true", help="delete candidates; default is dry-run"
    )
    args = parser.parse_args()
    if args.extension_cache_max_age_days < 1 or args.server_max_age_days < 1:
        parser.error("cache retention ages must be at least one day")
    if args.keep_latest < 1:
        parser.error("--keep-latest must be at least one")
    if any(not COMMIT.fullmatch(commit) for commit in args.protect_commit):
        parser.error("protected commits must be full 40-character lowercase hex hashes")
    return args


def main() -> int:
    args = parse_args()
    root = args.root
    if not root.exists() and not root.is_symlink():
        print(f"VS Code server cache root is absent: {root}")
        return 0
    if root.is_symlink() or not root.is_dir():
        print(f"VS Code server cache root is unsafe: {root}", file=sys.stderr)
        return 2

    now = time.time()
    cache_cutoff = now - args.extension_cache_max_age_days * 86400
    server_cutoff = now - args.server_max_age_days * 86400
    dry_run = not args.apply
    print("VS Code cache cleanup: dry-run" if dry_run else "VS Code cache cleanup: apply")
    cache_bytes = prune_extension_cache(root, cache_cutoff, args.apply)
    server_bytes = prune_server_builds(
        root,
        server_cutoff,
        args.keep_latest,
        set(args.protect_commit),
        args.require_protected_commit,
        args.apply,
    )
    print(
        f"candidate bytes: {(cache_bytes + server_bytes) / (1024**3):.2f} GiB "
        f"(extension cache {cache_bytes / (1024**3):.2f} GiB; "
        f"server builds {server_bytes / (1024**3):.2f} GiB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
