#!/usr/bin/env python3
"""Read-only release privacy gate. No downloads, execution of inputs or uploads.

Checks a staged tree or every Git object reachable from one immutable revision.
Reports rules and locations, never matched values. Private project markers must
live outside the release tree. A clean result is one gate, not a safety claim.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 1024 * 1024 * 1024
MAX_ITEMS = 50000
GIT = "/usr/bin/git"
HOME_PATH = re.compile(rb"/(?:Users|home)/([^/\s\x00\"'<>]+)")
EMAIL = re.compile(rb"[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,63}")
SYNTHETIC_USERS = {b"example", b"user", b"test", b"shared", b"...", b".."}
EXAMPLE_DOMAINS = {b"example.com", b"example.org", b"example.net", b"example.invalid", b"invalid.example", b"localhost.invalid"}
RULES = {
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "provider_credential": re.compile(rb"(?:xkeysib-[A-Za-z0-9\-]{24,}|gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{24,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})"),
    "private_chat_link": re.compile(rb"(?:chatgpt\.com/c/|chatgpt-conversation://)[a-zA-Z0-9:-]{12,}"),
    "signed_url": re.compile(rb"(?:X-Amz-Signature|X-Goog-Signature)=[a-fA-F0-9]{16,}"),
}
FORBIDDEN_NAMES = {".DS_Store", ".env", "credentials.json", "workspaces.json", "workspaces.local.json", "cookies.sqlite", "login.keychain-db"}
FORBIDDEN_DIRS = {".git", ".build", ".swiftpm", "__pycache__", "node_modules", ".macbridge", "local-secrets"}
FORBIDDEN_SUFFIXES = {".pem", ".key", ".p12", ".mobileprovision", ".sock"}
ARCHIVE_SUFFIXES = {".zip", ".dmg", ".tar", ".gz", ".tgz", ".bz2", ".xz", ".7z", ".rar"}


class GateError(Exception):
    pass


def regular_read(path, limit=MAX_FILE, *, dir_fd=None):
    """Never follow links or block opening a FIFO/device."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise GateError("non_regular_or_oversized_input")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            content = stream.read(limit + 1)
        after = os.fstat(fd)
        if len(content) > limit or (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise GateError("input_changed_or_size_limit")
        return content
    finally:
        os.close(fd)


class Gate:
    def __init__(self, markers=()):
        self.markers = tuple(markers)
        self.issues = []
        self.items = 0
        self.bytes = 0
        self.inventory = hashlib.sha256()

    def redacted(self, location):
        result = str(location)
        for marker in self.markers:
            result = re.sub(re.escape(marker), "[private]", result, flags=re.I)
        result = re.sub(r"/(Users|home)/[^/\s]+", r"/\1/[private]", result)
        return EMAIL.sub(b"[private-email]", result.encode("utf-8", "replace")).decode("utf-8")

    def issue(self, rule, location, line=None):
        item = {"rule": rule, "location": self.redacted(location)}
        if line is not None:
            item["line"] = line
        if item not in self.issues:
            self.issues.append(item)

    def inspect(self, data, location, *, account=True):
        if account:
            self.items += 1
            self.bytes += len(data)
            if self.items > MAX_ITEMS or self.bytes > MAX_TOTAL:
                raise GateError("scan_budget_exceeded")
            self.inventory.update(str(location).encode("utf-8", "surrogateescape") + b"\x00" + hashlib.sha256(data).digest())
        # UTF-16 source/resource strings are checked in addition to raw bytes.
        variants = [("raw", data)]
        if b"\x00" in data or data.startswith((b"\xff\xfe", b"\xfe\xff")):
            for encoding in ("utf-16-le", "utf-16-be"):
                variants.append((encoding, data.decode(encoding, "ignore").encode("utf-8")))
        for encoding, content in variants:
            hits = []
            for marker in self.markers:
                match = re.search(re.escape(marker.encode("utf-8")), content, re.I)
                if match:
                    hits.append(("private_marker", match.start()))
            for rule, pattern in RULES.items():
                hits.extend((rule, match.start()) for match in pattern.finditer(content))
            for match in HOME_PATH.finditer(content):
                if match.group(1).lower() not in SYNTHETIC_USERS:
                    hits.append(("machine_home_path", match.start()))
            for match in EMAIL.finditer(content):
                if match.group().rsplit(b"@", 1)[1].lower() not in EXAMPLE_DOMAINS:
                    hits.append(("non_example_email", match.start()))
            for rule, offset in hits:
                line = content.count(b"\n", 0, offset) + 1 if encoding == "raw" and b"\x00" not in content else None
                self.issue(rule, location, line)

    def name(self, name, location, is_dir=False):
        self.inspect(name.encode("utf-8", "surrogateescape"), location, account=False)
        if name in FORBIDDEN_NAMES or (is_dir and name in FORBIDDEN_DIRS) or Path(name).suffix.lower() in FORBIDDEN_SUFFIXES:
            self.issue("private_or_generated_entry", location)
        if name.startswith(".env.") and name not in {".env.example", ".env.sample"}:
            self.issue("private_or_generated_entry", location)
        if Path(name).suffix.lower() in ARCHIVE_SUFFIXES:
            self.issue("archive_requires_separate_inspection", location)

    def tree(self, root):
        root = Path(root)
        if root.is_symlink() or not root.is_dir():
            raise GateError("tree_root_must_be_regular_directory")
        # Resolve children against held directory descriptors, not mutable parents.
        def visit(folder_fd, prefix, depth=0):
            if depth > 64:
                raise GateError("tree_depth_limit")
            with os.scandir(folder_fd) as entries:
                for entry in sorted(entries, key=lambda value: value.name):
                    location = str(prefix / entry.name)
                    before = os.stat(entry.name, dir_fd=folder_fd, follow_symlinks=False)
                    mode = before.st_mode
                    self.name(entry.name, location, stat.S_ISDIR(mode))
                    if stat.S_ISLNK(mode):
                        self.issue("symlink_requires_review", location)
                    elif stat.S_ISDIR(mode):
                        self.inspect(b"directory", location)
                        if entry.name in FORBIDDEN_DIRS:
                            continue  # Already failed; never read credentials or build caches.
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=folder_fd)
                        try:
                            opened = os.fstat(child)
                            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                                raise GateError("directory_changed")
                            visit(child, Path(location), depth + 1)
                        finally:
                            os.close(child)
                    elif stat.S_ISREG(mode):
                        self.inspect(regular_read(entry.name, dir_fd=folder_fd), location)
                    else:
                        self.issue("non_regular_entry", location)
                    after = os.stat(entry.name, dir_fd=folder_fd, follow_symlinks=False)
                    if (before.st_dev, before.st_ino, before.st_mode, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_mode, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                        raise GateError("tree_entry_changed")
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            before = os.fstat(root_fd)
            visit(root_fd, Path())
            after = os.fstat(root_fd)
            if (before.st_mtime_ns, before.st_ctime_ns) != (after.st_mtime_ns, after.st_ctime_ns):
                raise GateError("tree_root_changed")
        finally:
            os.close(root_fd)

    def git(self, repo, revision):
        if not re.fullmatch(r"[a-fA-F0-9]{40}|[a-fA-F0-9]{64}", revision):
            raise GateError("git_requires_full_immutable_revision")
        env = dict(os.environ, GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
        command = [GIT, "-C", str(repo), "--no-optional-locks"]
        def git_read(*args):
            result = subprocess.run(command + list(args), env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            if result.returncode != 0 or len(result.stdout) > 8 * 1024 * 1024:
                raise GateError("git_read_failed_or_budget_exceeded")
            return result.stdout
        if git_read("rev-parse", "--is-shallow-repository").strip() != b"false":
            raise GateError("shallow_history_is_incomplete")
        actual = git_read("rev-parse", "--verify", revision + "^{commit}").decode("ascii").strip()
        if actual.lower() != revision.lower():
            raise GateError("revision_does_not_match")
        objects = git_read("rev-list", "--objects", "--no-object-names", actual).splitlines()
        if len(objects) > MAX_ITEMS:
            raise GateError("git_object_budget_exceeded")
        process = subprocess.Popen(command + ["cat-file", "--batch"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            for oid in objects:
                if not re.fullmatch(rb"[a-f0-9]{40}|[a-f0-9]{64}", oid):
                    raise GateError("invalid_object_id")
                process.stdin.write(oid + b"\n")
                process.stdin.flush()
                header = process.stdout.readline(160).split()
                if len(header) != 3 or header[0] != oid or not header[2].isdigit():
                    raise GateError("missing_or_invalid_git_object")
                size = int(header[2])
                if size > MAX_FILE:
                    raise GateError("git_object_size_limit")
                data = process.stdout.read(size)
                if len(data) != size or process.stdout.read(1) != b"\n":
                    raise GateError("truncated_git_object")
                location = "git-object/" + oid.decode("ascii")
                self.inspect(data, location)
                if header[1] == b"tree":
                    offset = 0
                    hash_bytes = len(oid) // 2
                    while offset < len(data):
                        end = data.index(b"\x00", offset)
                        mode, name = data[offset:end].split(b" ", 1)
                        self.name(os.fsdecode(name), location, mode == b"40000")
                        if mode in {b"120000", b"160000"}:
                            self.issue("symlink_or_submodule_requires_review", location)
                        offset = end + 1 + hash_bytes
                    if offset != len(data):
                        raise GateError("invalid_git_tree")
        finally:
            process.stdin.close()
            process.stdout.close()
            process.terminate()
            process.wait(timeout=10)

    def report(self, complete=True):
        return {"schema_version": 1, "status": "clear_within_rules" if complete and not self.issues else "blocked", "complete": complete,
                "items_checked": self.items, "bytes_checked": self.bytes, "inventory_sha256": self.inventory.hexdigest(),
                "issues": self.issues, "limitations": ["Rule-based checks do not prove absence of all private or encoded information.", "Compressed artifacts need independent inspection; source, history and built payloads are separate gates.", "No publication or execution approval is granted by this report."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("tree", "git"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--revision")
    parser.add_argument("--markers", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    gate = Gate()
    complete = False
    try:
        if args.markers:
            if args.markers.resolve().is_relative_to(args.root.resolve()):
                raise GateError("private_markers_must_stay_outside_target")
            markers = regular_read(args.markers, 65536).decode("utf-8").splitlines()
            if any(len(marker) < 3 for marker in markers if marker):
                raise GateError("private_marker_too_short")
            gate.markers = tuple(marker for marker in markers if marker)
        if args.mode == "tree":
            gate.tree(args.root)
        else:
            gate.git(args.root, args.revision or "")
        complete = True
    except (GateError, OSError, ValueError, subprocess.SubprocessError):
        # Exceptions can include private paths or Git stderr. Do not print them.
        gate.issue("inspection_incomplete", "input")
    report = gate.report(complete)
    encoded = json.dumps(report, indent=2, ensure_ascii=True) + "\n"
    if args.report:
        # Never overwrite a previous evidence artifact.
        with args.report.open("x", encoding="utf-8") as output:
            output.write(encoded)
    print(encoded, end="")
    return 0 if report["status"] == "clear_within_rules" else 1


if __name__ == "__main__":
    sys.exit(main())
