#!/usr/bin/env python3
"""Reject malformed, expired, revoked or non-signing OpenPGP keyrings."""

import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    armored = Path(sys.argv[1]).read_bytes().lstrip().startswith(b"-----BEGIN PGP PUBLIC KEY BLOCK-----")
    destination = sys.argv[2]
    if (destination.endswith(".asc") and not armored) or (destination.endswith(".gpg") and armored):
        sys.exit("Key format does not match its APT keyring filename")
    with tempfile.TemporaryDirectory(prefix="workstation-key-") as home:
        result = subprocess.run(
            ["gpg", "--homedir", home, "--batch", "--no-options", "--with-colons", "--show-keys", sys.argv[1]],
            capture_output=True,
            text=True,
            check=False,
        )
    if result.returncode:
        sys.exit("Invalid OpenPGP keyring: " + result.stderr.strip())
    primary_ok = False
    signing_ok = False
    primary_fingerprints = []
    expecting_primary_fingerprint = False
    now = int(time.time())
    for line in result.stdout.splitlines():
        fields = line.split(":")
        if fields[0] == "fpr" and expecting_primary_fingerprint:
            primary_fingerprints.append(fields[9])
            expecting_primary_fingerprint = False
        if fields[0] not in ("pub", "sub") or len(fields) < 12:
            continue
        valid = fields[1] not in ("e", "r", "d", "i") and (not fields[6] or int(fields[6]) > now)
        if fields[0] == "pub":
            primary_ok = valid
            expecting_primary_fingerprint = True
        if primary_ok and valid and "s" in fields[11]:
            signing_ok = True
    expected = sys.argv[3] if len(sys.argv) > 3 else ""
    allowed = set(expected.upper().split(",")) if expected else set()
    if allowed and (not primary_fingerprints or not set(primary_fingerprints).issubset(allowed)):
        sys.exit("Keyring contains an unexpected primary key fingerprint")
    if not allowed and len(primary_fingerprints) != 1:
        sys.exit("Keyring must contain exactly one primary key unless fingerprints are allowlisted")
    if not signing_ok:
        sys.exit("Keyring has no usable, unexpired signing key")


if __name__ == "__main__":
    main()
