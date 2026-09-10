"""Synthetic packaging guards; no software fixture is executed or installed."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from package_dmg import (GateError, attribute_names, build_payload, check_layout, file_manifest,
                         image_create_arguments, local_command, pinned_input, privacy_check, write_new)


class DMGPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mb-dmg-test-", dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.binary = self.root / "binaries"
        self.binary.mkdir()
        self.data = b"INERT FIXTURE - NEVER EXECUTED\n"
        self.digest = hashlib.sha256(self.data).hexdigest()
        for name in ["macbridge-mcp", "macbridge-observer"]:
            (self.binary / name).write_bytes(self.data)
            (self.binary / name).chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()  # exact owned synthetic tree, never broad cleanup

    def fake_command(self, arguments, timeout=60):
        if str(arguments[0]).endswith("lipo"):
            return b"arm64\n"
        if "--force" in arguments:
            app = Path(arguments[-1])
            write_new(app / "Contents/_CodeSignature/CodeResources", b"synthetic fixture seal")
        return b""

    def payload(self, name="new.noindex", markers=("example-private-marker",)):
        with patch("package_dmg.local_command", side_effect=self.fake_command):
            return build_payload(self.binary, self.root / name, self.digest, self.digest, markers)

    def testExactDigestAndByteCopyPreserveInput(self):
        source = self.binary / "macbridge-mcp"
        self.assertEqual(pinned_input(source, self.digest), self.data)
        payload, manifest, privacy = self.payload()
        self.assertEqual(privacy["status"], "clear_within_rules")
        self.assertEqual(manifest["MacBridge.app/Contents/MacOS/macbridge-mcp"]["sha256"], self.digest)
        self.assertEqual(source.read_bytes(), self.data)
        self.assertFalse((payload / "Applications").exists())

    def testMismatchRejectedBeforeCreatingOutput(self):
        with self.assertRaises(GateError):
            pinned_input(self.binary / "macbridge-mcp", "0" * 64)
        self.assertFalse((self.root / "new.noindex").exists())

    def testLeafAndAncestorAliasesRejected(self):
        leaf = self.root / "alias"
        leaf.symlink_to(self.binary / "macbridge-mcp")
        with self.assertRaises(GateError):
            pinned_input(leaf, self.digest)
        parent = self.root / "directory-alias"
        parent.symlink_to(self.binary, target_is_directory=True)
        with self.assertRaises(GateError):
            pinned_input(parent / "macbridge-mcp", self.digest)

    def testHardlinkAndWritableInputRejected(self):
        source = self.binary / "macbridge-mcp"
        link = self.root / "hardlink"
        os.link(source, link)
        with self.assertRaises(GateError):
            pinned_input(source, self.digest)
        link.unlink()
        source.chmod(0o777)
        with self.assertRaises(GateError):
            pinned_input(source, self.digest)

    def testQuarantineIsRejectedAndNotRemoved(self):
        source = self.binary / "macbridge-mcp"
        local_command(["/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;InertTest;", source])
        with self.assertRaises(GateError):
            pinned_input(source, self.digest)
        self.assertIn("com.apple.quarantine", attribute_names(source))

    def testPrivateInputBlockedBeforeCreatingOutput(self):
        with self.assertRaises(GateError):
            self.payload(markers=("INERT FIXTURE",))
        self.assertFalse((self.root / "new.noindex").exists())

    def testExistingOutputIsNeverChanged(self):
        existing = self.root / "new.noindex"
        existing.mkdir()
        sentinel = existing / "sentinel"
        sentinel.write_bytes(b"preserve existing data")
        with self.assertRaises(GateError):
            self.payload()
        self.assertEqual(sentinel.read_bytes(), b"preserve existing data")
        self.assertEqual(set(existing.iterdir()), {sentinel})

    def testOutputMustBeNewNoindexDirectory(self):
        with self.assertRaises(GateError):
            self.payload(name="indexed-folder")
        alias = self.root / "alias.noindex"
        alias.symlink_to(self.root / "elsewhere")
        with self.assertRaises(GateError):
            self.payload(name=alias.name)

    def testCopiesNoSourceExtendedMetadata(self):
        source = self.binary / "macbridge-mcp"
        local_command(["/usr/bin/xattr", "-w", "com.example.fixture-origin", "example-private-marker", source])
        payload, _, _ = self.payload()
        copied = payload / "MacBridge.app/Contents/MacOS/macbridge-mcp"
        self.assertNotIn("com.example.fixture-origin", attribute_names(copied))
        self.assertEqual(local_command(["/usr/bin/xattr", "-p", "com.example.fixture-origin", source]).strip(), b"example-private-marker")

    def testUnexpectedFileDirectoryOrSymlinkFailsLayout(self):
        payload, _, _ = self.payload()
        extra = payload / "unexpected"
        extra.mkdir()
        with self.assertRaises(GateError):
            check_layout(payload)
        extra.rmdir()
        extra.write_bytes(b"unlisted content")
        with self.assertRaises(GateError):
            check_layout(payload)
        extra.unlink()
        extra.symlink_to(self.root)
        with self.assertRaises(GateError):
            file_manifest(payload)

    def testPrivatePayloadFailsRescan(self):
        payload, _, _ = self.payload()
        with (payload / "Read Me.md").open("ab") as output:
            output.write(b"example-private-marker")
        with self.assertRaises(GateError):
            privacy_check(payload, ("example-private-marker",))

    def testExplicitPublicFileModesDoNotDependOnPackagerUmask(self):
        previous = os.umask(0o077)
        try:
            payload, manifest, _ = self.payload()
        finally:
            os.umask(previous)
        self.assertEqual(manifest["MacBridge.app/Contents/MacOS/macbridge-mcp"]["mode"], 0o755)
        self.assertEqual(manifest["Read Me.md"]["mode"], 0o644)
        self.assertEqual((payload / "MacBridge.app").stat().st_mode & 0o777, 0o755)

    def testDiskImageCreationPreservesSourceVolumeOwnership(self):
        arguments = image_create_arguments(Path("/private/tmp/fixture-payload"), Path("/private/tmp/fixture.dmg"))
        self.assertEqual(arguments[arguments.index("-srcowners") + 1], "any")
        self.assertIn("-nospotlight", arguments)
        self.assertIn("-noskipunreadable", arguments)
        self.assertNotIn("-ov", arguments)
        self.assertNotIn("-srcdevice", arguments)
        self.assertNotIn("-attach", arguments)


if __name__ == "__main__":
    unittest.main()
