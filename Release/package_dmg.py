#!/usr/bin/env python3
"""Package reviewed release binaries into an offline development DMG.

No download, installation, app launch, credential read or security bypass.
Inputs are copied as bytes from a fixed allowlist, not from an installed app.
The output directory must be new and end in .noindex. Failed outputs are kept.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import tempfile

from privacy_gate import Gate, GateError, regular_read

SOURCE = Path(__file__).resolve().parent.parent
BRAND_HASHES = {
    "macbridge-icon.png": "0f44186f16ac6e2d02d74b089fcc664f209c3d6a22931e528ed5cf33b905864d",
    "MacBridge.icns": "0f595efa6ed24c1e50adcd32474b01caea842d7a2170027e8d515ade535f5f71",
}
APP_FILES = {
    "Contents/MacOS/macbridge-mcp", "Contents/MacOS/macbridge-observer",
    "Contents/Info.plist", "Contents/Resources/MacBridge.png",
    "Contents/Resources/MacBridge.icns", "Contents/_CodeSignature/CodeResources",
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def local_command(arguments, timeout=60):
    result = subprocess.run([str(value) for value in arguments], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False,
                            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": tempfile.gettempdir()})
    if result.returncode != 0:
        # Vendor diagnostics can include machine paths. Keep them out of the
        # public receipt; a failed exact step is still reported, never ignored.
        raise GateError(Path(arguments[0]).name + "_failed_exit_" + str(result.returncode))
    return result.stdout


def pinned_input(path, digest):
    path = Path(path)
    if path.resolve() != path or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise GateError("noncanonical_input_or_invalid_digest")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o022:
        raise GateError("unexpected_input_type_links_or_permissions")
    if "com.apple.quarantine" in attribute_names(path):
        raise GateError("quarantined_input_requires_separate_review")
    data = regular_read(path)
    if sha256(data) != digest:
        raise GateError("input_digest_mismatch")
    return data


def attribute_names(path):
    # CPython's os.*xattr APIs are Linux-specific. Use the already installed
    # macOS reader, with -s so it never dereferences a symlink. No values read.
    return local_command(["/usr/bin/xattr", "-s", path]).decode("utf-8").splitlines()


def write_new(path, data, mode=0o644):
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    for parent in reversed(missing):
        parent.mkdir(mode=0o755)
        parent.chmod(0o755)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        os.fchmod(output.fileno(), mode)
    # Byte-copy only: source ownership, ACLs, resource forks, Finder metadata,
    # origin URLs and extended attributes are not imported into the new tree.


def file_manifest(root):
    result = {}
    def visit(folder):
        for path in sorted(folder.iterdir()):
            info = path.lstat()
            if stat.S_ISDIR(info.st_mode):
                result[str(path.relative_to(root)) + "/"] = {"directory": True}
                visit(path)
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                result[str(path.relative_to(root))] = {"sha256": sha256(regular_read(path)),
                    "bytes": info.st_size, "mode": stat.S_IMODE(info.st_mode)}
            else:
                raise GateError("unexpected_payload_entry")
    visit(root)
    return result


def check_layout(payload):
    manifest = file_manifest(payload)
    expected = {"MacBridge.app/" + name for name in APP_FILES} | {"Read Me.md", ".metadata_never_index"}
    expected |= {"MacBridge.app/", "MacBridge.app/Contents/", "MacBridge.app/Contents/MacOS/",
                 "MacBridge.app/Contents/Resources/", "MacBridge.app/Contents/_CodeSignature/"}
    if set(manifest) != expected:
        raise GateError("unexpected_payload_file_set")
    return manifest


def privacy_check(root, markers):
    gate = Gate(markers)
    gate.tree(root)
    report = gate.report()
    if report["status"] != "clear_within_rules":
        raise GateError("payload_privacy_gate_blocked")
    return report


def validate_output(output):
    output = Path(output)
    if not output.is_absolute() or output.resolve() != output or not output.name.endswith(".noindex"):
        raise GateError("output_requires_new_canonical_noindex_directory")
    if output.exists() or output.is_symlink():
        raise GateError("refusing_existing_output")


def build_payload(binary_directory, output, core_hash, ui_hash, markers):
    output = Path(output)
    validate_output(output)
    inputs = {}
    for name, digest in [("macbridge-mcp", core_hash), ("macbridge-observer", ui_hash)]:
        path = Path(binary_directory) / name
        inputs["Contents/MacOS/" + name] = pinned_input(path, digest)
        local_command(["/usr/bin/codesign", "--verify", "--strict", path])
        if local_command(["/usr/bin/lipo", "-archs", path]).strip() != b"arm64":
            raise GateError("this_development_package_requires_arm64_inputs")
    for name, digest in BRAND_HASHES.items():
        key = "Contents/Resources/" + ("MacBridge.png" if name.endswith(".png") else name)
        inputs[key] = pinned_input(SOURCE / "Assets/Brand" / name, digest)
    inputs["Contents/Info.plist"] = regular_read(SOURCE / "Observer/Info.plist")
    plist = plistlib.loads(inputs["Contents/Info.plist"])
    if (plist.get("CFBundleIdentifier"), plist.get("CFBundleExecutable"), plist.get("CFBundleShortVersionString")) != (
            "local.macbridge.observer", "macbridge-observer", "0.3.0"):
        raise GateError("unexpected_bundle_identity")
    readme = regular_read(SOURCE / "Release/FIRST-RUN.md")
    gate = Gate(markers)
    for name, data in dict(inputs, readme=readme).items():
        gate.inspect(data, name)
    if gate.issues:
        raise GateError("input_privacy_gate_blocked")
    output.mkdir(mode=0o700)  # atomic reservation; never overwrite another run
    payload = output / "payload"
    app = payload / "MacBridge.app"
    for name, data in inputs.items():
        write_new(app / name, data, 0o755 if "/MacOS/" in name else 0o644)
    write_new(payload / "Read Me.md", readme)
    write_new(payload / ".metadata_never_index", b"")
    local_command(["/usr/bin/codesign", "--force", "--sign", "-", app])
    local_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    manifest = check_layout(payload)
    if manifest["MacBridge.app/Contents/MacOS/macbridge-mcp"]["sha256"] != core_hash:
        raise GateError("packaging_changed_core")
    privacy = privacy_check(payload, markers)
    return payload, manifest, privacy


def image_create_arguments(payload, image):
    # "any" leaves source-volume ownership unchanged. Never use on/off here:
    # those options can request changing an existing source volume's setting.
    return ["/usr/bin/hdiutil", "create", "-srcfolder", payload, "-fs", "HFS+",
        "-format", "UDZO", "-volname", "MacBridge", "-nospotlight", "-srcowners", "any",
        "-noskipunreadable", image]


def build_and_verify_image(payload, output, manifest, markers):
    image = output / "MacBridge-0.3.0-arm64-development.dmg"
    local_command(image_create_arguments(payload, image), timeout=180)
    local_command(["/usr/bin/hdiutil", "verify", image], timeout=120)
    mount = Path(tempfile.mkdtemp(prefix="mb-dmg-check-", dir="/private/tmp"))
    try:
        response = plistlib.loads(local_command(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
            "-owners", "off", "-mountpoint", mount, "-plist", image], timeout=90))
        mounts = [entry.get("mount-point") for entry in response.get("system-entities", []) if entry.get("mount-point")]
        if mounts != [str(mount)] or not os.path.ismount(mount):
            raise GateError("unexpected_image_mount")
        actual = check_layout(mount)
        if actual != manifest:
            raise GateError("mounted_payload_differs")
        local_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", mount / "MacBridge.app"])
        privacy = privacy_check(mount, markers)
    finally:
        # Only our newly created mount point. No force detach, global cleanup,
        # installed app removal or source-tree deletion is permitted here.
        if os.path.ismount(mount):
            local_command(["/usr/bin/hdiutil", "detach", mount], timeout=60)
        mount.rmdir()
    return image, privacy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-directory", required=True, type=Path)
    parser.add_argument("--core-sha256", required=True)
    parser.add_argument("--ui-sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--private-markers", required=True, type=Path)
    args = parser.parse_args()
    validate_output(args.output)
    if args.output.resolve().is_relative_to(SOURCE):
        raise GateError("output_must_be_outside_source")
    if args.private_markers.resolve().is_relative_to(args.output.resolve()):
        raise GateError("private_markers_must_be_outside_output")
    markers = tuple(line for line in regular_read(args.private_markers, 65536).decode("utf-8").splitlines() if line)
    if not markers or any(len(line) < 3 for line in markers):
        raise GateError("explicit_private_markers_required")
    # File-provider-backed Documents folders may inject Finder metadata into
    # app bundles after creation, which makes codesign reject them. Build in a
    # fresh non-synced, non-indexed local directory instead of clearing metadata
    # or weakening signature checks. Keep it for inspection if any step fails.
    stage = Path(tempfile.mkdtemp(prefix="mb-dmg-build-", suffix=".noindex", dir="/private/tmp"))
    stage_output = stage / "artifact.noindex"
    print(json.dumps({"local_staging_directory": str(stage)}), flush=True)
    payload, manifest, privacy = build_payload(args.binary_directory, stage_output,
        args.core_sha256, args.ui_sha256, markers)
    image, mounted_privacy = build_and_verify_image(payload, stage_output, manifest, markers)
    image_bytes = regular_read(image)
    receipt = {"schema_version": 1, "status": "development_image_verified", "distribution_ready": False,
        "architecture": "arm64", "signing": "ad-hoc", "notarized": False,
        "image": {"name": image.name, "sha256": sha256(image_bytes), "bytes": len(image_bytes)},
        "input_core_sha256": args.core_sha256, "input_ui_sha256": args.ui_sha256,
        "payload_files": manifest, "payload_privacy": privacy, "mounted_privacy": mounted_privacy,
        "limitations": ["No app installation or launch, real-user first-run, reboot or ChatGPT-host test was performed.",
            "Ad-hoc signing is not publisher verification. Do not bypass macOS security controls.",
            "Source history, signing/notarization, clean-machine acceptance and publication approval remain separate gates."]}
    args.output.mkdir(mode=0o700)
    write_new(args.output / image.name, image_bytes)
    if sha256(regular_read(args.output / image.name)) != receipt["image"]["sha256"]:
        raise GateError("exported_image_differs")
    write_new(args.output / "receipt.json", (json.dumps(receipt, indent=2) + "\n").encode())
    print(json.dumps({key: receipt[key] for key in ["status", "distribution_ready", "image"]}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (GateError, OSError, ValueError, subprocess.SubprocessError) as error:
        # Only our bounded rule names are safe diagnostics; no raw OS paths,
        # command output, marker values or source excerpts are printed.
        label = str(error) if isinstance(error, GateError) else type(error).__name__
        print(json.dumps({"status": "blocked", "rule": label}))
        raise SystemExit(1)
