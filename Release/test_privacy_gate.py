"""Synthetic tests only. Git writes are confined to each new temporary fixture."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import privacy_gate as pg


class PrivacyGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mb-release-gate-", dir="/private/tmp")
        self.base = Path(self.temp.name)
        self.root = self.base / "source"
        self.root.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def run_gate(self, *args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = pg.main(list(args))
        return status, json.loads(output.getvalue())

    def test_clean_tree(self):
        (self.root / "hello.swift").write_text("print(42)\n")
        code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 0)
        self.assertTrue(result["complete"])
        self.assertEqual(result["items_checked"], 1)

    def test_deterministic_inventory_and_content_binding(self):
        target = self.root / "a"
        target.write_text("first")
        first = self.run_gate("tree", str(self.root))[1]
        second = self.run_gate("tree", str(self.root))[1]
        self.assertEqual(first["inventory_sha256"], second["inventory_sha256"])
        target.write_text("second")
        self.assertNotEqual(first["inventory_sha256"], self.run_gate("tree", str(self.root))[1]["inventory_sha256"])

    def test_private_marker_never_in_report(self):
        marker = "fixture-private-person"
        markers = self.base / "private-list.txt"
        markers.write_text(marker + "\n")
        (self.root / (marker + ".txt")).write_text("a\n" + marker.upper())
        code, result = self.run_gate("tree", str(self.root), "--markers", str(markers))
        self.assertEqual(code, 1)
        self.assertNotIn(marker, json.dumps(result).lower())
        self.assertIn("private_marker", {x["rule"] for x in result["issues"]})

    def test_private_marker_file_cannot_be_exported(self):
        markers = self.root / "private.txt"
        markers.write_text("private-fixture")
        code, result = self.run_gate("tree", str(self.root), "--markers", str(markers))
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])

    def test_utf16_both_endiannesses(self):
        for encoding in ("utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                gate = pg.Gate(["fixture-private-person"])
                gate.inspect("fixture-private-person".encode(encoding), "asset")
                self.assertTrue(gate.issues)

    def test_machine_path_and_non_example_email(self):
        gate = pg.Gate()
        path = "/" + "Users" + "/private-person/Documents/work"
        email = "private-person" + "@" + "private-mail.invalid"
        gate.inspect((path + "\n" + email).encode(), "fixture")
        self.assertEqual({x["rule"] for x in gate.issues}, {"machine_home_path", "non_example_email"})
        self.assertNotIn(email, json.dumps(gate.report()))

    def test_example_email_and_home_are_allowed(self):
        gate = pg.Gate()
        gate.inspect(("/" + "Users" + "/example/project\nauthor@example.invalid").encode(), "fixture")
        self.assertEqual(gate.issues, [])

    def test_credential_shapes_without_printing_them(self):
        for prefix in ("xkeysib-", "ghp_", "github_pat_", "sk-proj-"):
            with self.subTest(prefix=prefix):
                value = (prefix + "F" * 48).encode()
                gate = pg.Gate()
                gate.inspect(value, "fixture")
                self.assertIn("provider_credential", {x["rule"] for x in gate.issues})
                self.assertNotIn(value.decode(), json.dumps(gate.report()))

    def test_private_key_and_chat_url(self):
        gate = pg.Gate()
        gate.inspect(("-----BEGIN " + "PRIVATE KEY-----\nhttps://chatgpt.com/" + "c/12345678-abcd-ef01-2345-67890abcdef1").encode(), "fixture")
        self.assertEqual({x["rule"] for x in gate.issues}, {"private_key", "private_chat_link"})

    def test_all_builtin_location_matches_are_removed_before_storage(self):
        cases = [
            ("provider_credential", "gh" + "p_" + "A" * 36),
            ("signed_url", "X-Amz-" + "Signature=" + "a" * 32),
            ("signed_url", "X-Goog-" + "Signature=" + "b" * 32),
            ("private_key", "-----BEGIN " + "PRIVATE KEY-----"),
            ("private_chat_link", "chatgpt.com/" + "c/" + "1234abcd" * 4),
            ("private_chat_link", "chatgpt-" + "conversation://" + "1234abcd" * 4),
        ]
        for rule, value in cases:
            with self.subTest(rule=rule):
                gate = pg.Gate()
                location = "parent/" + value + "/file"
                gate.issue("symlink_requires_review", location)
                gate.inspect(value.encode(), location)
                self.assertIn(rule, {item["rule"] for item in gate.issues})
                self.assertTrue(all(item["location"] == "parent/[private]/file" for item in gate.issues))
                self.assertNotIn(value, json.dumps(gate.issues))
                self.assertNotIn(value, json.dumps(gate.report()))

    def test_filename_and_parent_tokens_are_absent_from_both_report_sinks(self):
        for index, value in enumerate(("gh" + "p_" + "A" * 36,
                "X-Amz-" + "Signature=" + "b" * 32)):
            with self.subTest(index=index):
                folder = self.root / (value + ".folder")
                folder.mkdir()
                (folder / (value + ".txt")).write_text("inert fixture")
                (folder / "outside-link").symlink_to("../not-followed")
                report = self.base / ("report-" + str(index) + ".json")
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    code = pg.main(["tree", str(self.root), "--report", str(report)])
                self.assertEqual(code, 1)
                self.assertEqual(output.getvalue(), report.read_text())
                self.assertNotIn(value, output.getvalue())
                self.assertIn("symlink_requires_review", output.getvalue())

    def test_redaction_handles_overlaps_in_both_directions(self):
        token = "gh" + "p_" + "A" * 36
        gate = pg.Gate([token[6:12]])
        self.assertEqual(gate.redacted("dir/" + token + "/file"), "dir/[private]/file")
        marker = "prefix-" + token + "-tail"
        gate = pg.Gate([marker])
        self.assertEqual(gate.redacted("dir/" + marker + "/file"), "dir/[private]/file")

    def test_location_unicode_invalid_bytes_and_marker_changes(self):
        token = "gh" + "p_" + "A" * 36
        location = os.fsdecode(b"dir/\xff" + token.encode() + b"/file")
        gate = pg.Gate()
        self.assertNotIn(token, gate.redacted(location))
        self.assertEqual(gate.redacted("src/naïve.swift"), "src/naïve.swift")
        gate.markers = ("Fixture-Ä-Private",)
        self.assertEqual(gate.redacted("dir/fixture-ä-private/file"), "dir/[private]/file")
        gate.markers = ("naïve",)
        self.assertEqual(gate.redacted("src/naïve.swift"), "src/[private].swift")

    def test_dense_lines_preserve_order_without_quadratic_prefix_scans(self):
        class CountingBytes(bytes):
            scanned = 0
            nul_checks = 0

            def count(self, sub, start=0, end=None):
                stop = len(self) if end is None else end
                self.scanned += stop - start
                return super().count(sub, start, stop)

            def __contains__(self, item):
                if item == b"\x00":
                    self.nul_checks += 1
                return super().__contains__(item)

        class NoListMembership(list):
            def __contains__(self, item):
                raise AssertionError("deduplication must not scan the growing issue list")

        token = "gh" + "p_" + "A" * 36
        data = CountingBytes(((token + "\n") * 1000).encode())
        gate = pg.Gate()
        gate.issues = NoListMembership()
        gate.inspect(data, "fixture")
        self.assertEqual([item["line"] for item in gate.issues], list(range(1, 1001)))
        self.assertLessEqual(data.scanned, len(data))
        self.assertLessEqual(data.nul_checks, 3)

    def test_home_location_redaction_covers_byte_whitespace_and_filename_punctuation(self):
        for character in ("\u00a0", "\u2003", "'", '"', "<", ">"):
            for prefix in ("Users", "home"):
                with self.subTest(character=repr(character), prefix=prefix):
                    username = character + "private-fixture" + character + "suffix"
                    location = "parent/" + prefix + "/" + username + "/file.pem"
                    gate = pg.Gate()
                    gate.name("file.pem", location)
                    expected = "parent/" + prefix + "/[private]/file.pem"
                    self.assertEqual(gate.issues[0]["location"], expected)
                    self.assertNotIn("private-fixture", json.dumps(gate.report()))
                    self.assertNotIn("suffix", json.dumps(gate.report()))
                    if character in ("\u00a0", "\u2003"):
                        self.assertIsNotNone(pg.HOME_PATH.search(location.encode()))
                        gate.inspect(location.encode(), location)
                        self.assertIn("machine_home_path", {item["rule"] for item in gate.issues})
                        self.assertTrue(all(item["location"] == expected for item in gate.issues))

    def test_dense_single_line_and_binary_matches_are_deduplicated(self):
        token = "gh" + "p_" + "A" * 36
        gate = pg.Gate()
        gate.inspect(((token + " ") * 4000).encode(), "fixture")
        self.assertEqual(gate.issues, [{"rule": "provider_credential", "location": "fixture", "line": 1}])
        for encoding in ("utf-16-le", "utf-16-be"):
            with self.subTest(encoding=encoding):
                gate = pg.Gate()
                gate.inspect(((token + "\n") * 1000).encode(encoding), "binary")
                self.assertEqual(gate.issues, [{"rule": "provider_credential", "location": "binary"}])

    def test_matching_order_and_line_semantics_are_unchanged(self):
        token = "gh" + "p_" + "A" * 36
        signed = "X-Amz-" + "Signature=" + "b" * 32
        home = "/" + "Users" + "/private-fixture/file"
        email = "private-fixture" + "@" + "non-example.invalid"
        data = ("marker-fixture " + token + "\n" + signed + " " + token + "\n" + home + "\n" + email).encode()
        gate = pg.Gate(["marker-fixture"])
        gate.inspect(data, "fixture")
        self.assertEqual([(item["rule"], item["line"]) for item in gate.issues], [
            ("private_marker", 1), ("provider_credential", 1), ("provider_credential", 2),
            ("signed_url", 2), ("machine_home_path", 3), ("non_example_email", 4)])
        gate = pg.Gate(["\nZZ"])
        gate.inspect(b"\nZZ", "fixture")
        self.assertEqual(gate.issues[0]["line"], 1)

    def test_issue_budget_is_explicit_and_fails_closed_even_for_direct_callers(self):
        token = "gh" + "p_" + "A" * 36
        data = ((token + "\n") * 5).encode()
        with patch.object(pg, "MAX_ISSUES", 3):
            gate = pg.Gate()
            with self.assertRaises(pg.GateError):
                gate.inspect(data, "fixture")
            self.assertEqual(len(gate.issues), 3)
            self.assertFalse(gate.report()["complete"])
            self.assertEqual(gate.report()["status"], "blocked")
            self.assertTrue(gate.report()["issues_truncated"])
            self.assertEqual(gate.report()["issue_limit"], 3)
            with self.assertRaises(pg.GateError):
                gate.inspect(b"clean", "later")
            (self.root / "dense.txt").write_bytes(data)
            code, report = self.run_gate("tree", str(self.root))
            self.assertEqual(code, 1)
            self.assertFalse(report["complete"])
            self.assertEqual(len(report["issues"]), 4)
            self.assertEqual(report["issues"][-1], {"rule": "inspection_incomplete", "location": "input"})
            self.assertNotIn(token, json.dumps(report))

    def test_reaching_exact_issue_budget_does_not_truncate_a_complete_scan(self):
        token = "gh" + "p_" + "A" * 36
        with patch.object(pg, "MAX_ISSUES", 3):
            gate = pg.Gate()
            gate.inspect(((token + "\n") * 3).encode(), "fixture")
            self.assertTrue(gate.report()["complete"])
            self.assertFalse(gate.report()["issues_truncated"])
            gate.issue("provider_credential", "fixture", 1)
            self.assertEqual(len(gate.issues), 3)

    def test_symlink_outside_is_not_read(self):
        outside = self.base / "outside"
        outside.write_text("private-fixture")
        (self.root / "link").symlink_to(outside)
        with patch.object(pg, "regular_read", side_effect=AssertionError("must not read link")):
            code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertEqual(result["issues"][0]["rule"], "symlink_requires_review")

    def test_directory_symlink_not_followed(self):
        (self.root / "link").symlink_to(self.base, target_is_directory=True)
        code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertEqual(result["items_checked"], 0)

    def test_fifo_is_not_opened(self):
        os.mkfifo(self.root / "pipe")
        code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertEqual(result["issues"][0]["rule"], "non_regular_entry")

    def test_generated_directory_fails_without_reading_cache(self):
        folder = self.root / ".build"
        folder.mkdir()
        (folder / "cached.bin").write_bytes(b"private-cache")
        with patch.object(pg, "regular_read", side_effect=AssertionError("must not read cache")):
            code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertTrue(result["complete"])

    def test_archives_are_not_marked_clean(self):
        (self.root / "payload.zip").write_bytes(b"fixture")
        code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertIn("archive_requires_separate_inspection", {x["rule"] for x in result["issues"]})

    def test_oversize_and_read_errors_fail_closed(self):
        (self.root / "payload").write_text("fixture")
        with patch.object(pg, "regular_read", side_effect=pg.GateError("private diagnostic")):
            code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])
        self.assertNotIn("private diagnostic", json.dumps(result))

    def test_scan_budget_fails_closed(self):
        (self.root / "a").write_text("a")
        with patch.object(pg, "MAX_ITEMS", 0):
            code, result = self.run_gate("tree", str(self.root))
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])

    def test_report_is_exclusive(self):
        report = self.base / "report.json"
        report.write_text("original")
        with self.assertRaises(FileExistsError):
            self.run_gate("tree", str(self.root), "--report", str(report))
        self.assertEqual(report.read_text(), "original")

    def git_command(self, *args):
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME="Release Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                   GIT_COMMITTER_NAME="Release Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        return subprocess.check_output([pg.GIT, "-C", str(self.root), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args], env=env, stderr=subprocess.DEVNULL).decode().strip()

    def test_git_reads_deleted_history_and_author_metadata(self):
        self.git_command("init", "--quiet")
        marker = "private-fixture-in-history"
        markers = self.base / "markers"
        markers.write_text(marker)
        (self.root / "old.txt").write_text(marker)
        self.git_command("add", "old.txt")
        self.git_command("commit", "--quiet", "-m", "fixture commit")
        (self.root / "old.txt").write_text("clean now")
        self.git_command("add", "old.txt")
        self.git_command("commit", "--quiet", "-m", "clean fixture tip")
        revision = self.git_command("rev-parse", "HEAD")
        code, result = self.run_gate("git", str(self.root), "--revision", revision, "--markers", str(markers))
        self.assertEqual(code, 1)
        self.assertTrue(result["complete"])
        self.assertIn("private_marker", {x["rule"] for x in result["issues"]})
        self.assertNotIn(marker, json.dumps(result))

    def test_git_clean_history(self):
        self.git_command("init", "--quiet")
        (self.root / "a").write_text("hello")
        self.git_command("add", "a")
        self.git_command("commit", "--quiet", "-m", "clean fixture")
        revision = self.git_command("rev-parse", "HEAD")
        self.assertEqual(self.run_gate("git", str(self.root), "--revision", revision)[0], 0)

    def test_git_private_author_is_detected_without_printing_identity(self):
        self.git_command("init", "--quiet")
        (self.root / "a").write_text("hello")
        self.git_command("add", "a")
        private_email = "fixture-private-person" + "@" + "private-mail.tld"
        self.git_command("commit", "--quiet", "--author", "Fixture <" + private_email + ">", "-m", "fixture")
        revision = self.git_command("rev-parse", "HEAD")
        code, result = self.run_gate("git", str(self.root), "--revision", revision)
        self.assertEqual(code, 1)
        self.assertIn("non_example_email", {x["rule"] for x in result["issues"]})
        self.assertNotIn(private_email, json.dumps(result))

    def test_git_symlink_is_not_treated_as_an_audited_external_target(self):
        self.git_command("init", "--quiet")
        (self.root / "link").symlink_to("../outside")
        self.git_command("add", "link")
        self.git_command("commit", "--quiet", "-m", "fixture link")
        revision = self.git_command("rev-parse", "HEAD")
        code, result = self.run_gate("git", str(self.root), "--revision", revision)
        self.assertEqual(code, 1)
        self.assertIn("symlink_or_submodule_requires_review", {x["rule"] for x in result["issues"]})

    def test_git_mutable_ref_rejected(self):
        code, result = self.run_gate("git", str(self.root), "--revision", "main")
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])

    def test_git_shallow_history_rejected(self):
        self.git_command("init", "--quiet")
        (self.root / "a").write_text("hello")
        self.git_command("add", "a")
        self.git_command("commit", "--quiet", "-m", "fixture")
        revision = self.git_command("rev-parse", "HEAD")
        (self.root / ".git" / "shallow").write_text(revision + "\n")
        code, result = self.run_gate("git", str(self.root), "--revision", revision)
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])


if __name__ == "__main__":
    unittest.main()
