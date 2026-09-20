#!/usr/bin/env python3
"""Exercise packaging only; never launch binaries, install, or change a live app.

Requires already-reviewed signed raw binaries and an existing valid source app.
All generated fixtures/results stay in one new /private/tmp/*.noindex directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def entry_metadata(path):
    info = path.lstat()
    result = {"mode": stat.S_IMODE(info.st_mode)}
    if stat.S_ISLNK(info.st_mode):
        result.update(type="symlink", target=os.readlink(path))
    elif stat.S_ISDIR(info.st_mode):
        result.update(type="directory")
    elif stat.S_ISREG(info.st_mode):
        result.update(type="file", size=info.st_size, sha256=digest(path))
    else:
        result.update(type="special", file_type=stat.S_IFMT(info.st_mode))
    return result


def manifest(path):
    result = {}

    def visit(current):
        metadata = entry_metadata(current)
        result[str(current.relative_to(path))] = metadata
        if metadata["type"] == "directory":
            for child in sorted(current.iterdir()):
                visit(child)

    visit(path)
    return result


def run(args, *, umask=-1):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, check=False, umask=umask)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check_manifest(root):
    fixture = root / "manifest-self-check"
    fixture.mkdir()
    payload = fixture / "payload"
    payload.write_bytes(b"unchanged manifest fixture\n")
    payload.chmod(0o640)
    (fixture / "empty").mkdir()
    link = fixture / "link"
    link.symlink_to("payload")
    (fixture / "directory-link").symlink_to(".", target_is_directory=True)
    before = manifest(fixture)
    require(before["empty"]["type"] == "directory", "Manifest omitted an empty directory")
    require(before["link"] == {"type": "symlink", "mode": stat.S_IMODE(link.lstat().st_mode), "target": "payload"}, "Manifest followed or omitted symlink")
    require(not any(name.startswith("directory-link/") for name in before), "Manifest followed directory symlink")

    payload.chmod(0o600)
    changed = manifest(fixture)
    require(changed != before and changed["payload"]["sha256"] == before["payload"]["sha256"], "Manifest missed chmod-only change")
    payload.chmod(before["payload"]["mode"])
    require(manifest(fixture) == before, "chmod fixture did not restore")
    extra = fixture / "new-empty-directory"
    extra.mkdir()
    require(manifest(fixture) != before, "Manifest missed empty-directory addition")
    extra.rmdir()
    require(manifest(fixture) == before, "Directory fixture did not restore")
    link.unlink()
    link.symlink_to("different-literal-target")
    require(manifest(fixture) != before, "Manifest missed symlink target change")
    link.unlink()
    link.symlink_to("payload")
    require(manifest(fixture) == before, "Symlink fixture did not restore")
    return ["chmod-only", "empty-directory", "literal-symlink-target-no-follow"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary-directory", required=True, type=Path)
    parser.add_argument("--source-app", required=True, type=Path)
    args = parser.parse_args()
    raw = args.binary_directory.resolve(strict=True)
    source = args.source_app.resolve(strict=True)
    package = Path(__file__).resolve().parents[1] / "package-observer.sh"
    for target in (raw / "macbridge-mcp", raw / "macbridge-observer", source):
        result = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", target])
        require(result.returncode == 0, f"Input signature invalid: {target}\n{result.stderr}")

    before = manifest(source)
    raw_before = {name: entry_metadata(raw / name) for name in ("macbridge-mcp", "macbridge-observer")}
    root = Path(tempfile.mkdtemp(prefix="macbridge-package-tests-", suffix=".noindex", dir="/private/tmp"))
    print(f"Evidence: {root}", flush=True)
    results = []
    manifest_checks = check_manifest(root)

    def case(name, arguments, success, destination=None, *, umask=-1):
        result = run(["/bin/sh", package, *arguments], umask=umask)
        (root / f"{name}.log").write_text(result.stdout + result.stderr)
        require((result.returncode == 0) == success, f"{name}: unexpected exit {result.returncode}\n{result.stderr}")
        if not success and destination is not None:
            require(not destination.exists(), f"{name}: created destination before rejecting inputs")
        results.append({"name": name, "exit_code": result.returncode, "passed": True, "umask": "inherited" if umask < 0 else f"{umask:04o}"})

    raw_app = root / "raw" / "MacBridge.app"
    case("raw-binaries", [raw, raw_app], True)
    require(entry_metadata(raw_app / "Contents/MacOS/macbridge-mcp") == raw_before["macbridge-mcp"], "Raw mode changed core bytes or metadata")
    brand = package.parent.parent / "Assets" / "Brand"
    packaged_png = raw_app / "Contents/Resources/MacBridge.png"
    packaged_icns = raw_app / "Contents/Resources/MacBridge.icns"
    packaged_notice = raw_app / "Contents/Resources/ThirdPartyNotices.txt"
    require(packaged_png.is_file() and digest(packaged_png) == digest(brand / "macbridge-icon.png"),
            "Raw package omitted or changed the canonical PNG logo")
    require(packaged_icns.is_file() and digest(packaged_icns) == digest(brand / "MacBridge.icns"),
            "Raw package omitted or changed the Finder/Dock icon")
    require(packaged_notice.is_file() and digest(packaged_notice) == digest(package.parent / "CODENOTCH-LICENSE.txt"),
            "Raw package omitted or changed the CodeNotch MIT notice")
    plist = run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIconFile", raw_app / "Contents/Info.plist"])
    require(plist.returncode == 0 and plist.stdout.strip() == "MacBridge", "Raw package does not declare the bundle icon")
    agent_app = run(["/usr/libexec/PlistBuddy", "-c", "Print :LSUIElement", raw_app / "Contents/Info.plist"])
    require(agent_app.returncode == 0 and agent_app.stdout.strip().lower() == "true",
            "Raw package would add a Dock icon instead of behaving as a compact menu-bar app")
    display_name = run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleDisplayName", raw_app / "Contents/Info.plist"])
    require(display_name.returncode == 0 and display_name.stdout.strip() == "MacBridge",
            "Raw package still exposes a preview-only app name")
    version = run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", raw_app / "Contents/Info.plist"])
    require(version.returncode == 0 and version.stdout.strip() == "0.4.0",
            "Observer app version is not aligned with the 0.4 runtime")

    # This is a full copy of a signed app, not its extracted, bundle-bound UI binary.
    fixture = root / "source" / "MacBridge.app"
    shutil.copytree(source, fixture)
    require(manifest(fixture) == before, "Source fixture copy differs")
    # Change only a copied core's ad-hoc signature identifier, so this test also
    # detects accidentally keeping the source app's core. Never execute it.
    candidate = root / "candidate-mcp"
    shutil.copy2(raw / "macbridge-mcp", candidate)
    signed = run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "local.macbridge.packaging-test", candidate])
    require(signed.returncode == 0, f"Could not sign copied test core: {signed.stderr}")
    candidate_before = entry_metadata(candidate)
    require(candidate_before["sha256"] != before["Contents/MacOS/macbridge-mcp"]["sha256"], "Test core must differ from source app core")
    preserved = root / "preserved" / "MacBridge.app"
    # Normal-Chat jobs use a private umask; do not let a permissive test shell
    # hide a changed app-root mode when ditto copies into the reserved directory.
    case("preserved-ui-distinct-core", ["--preserve-ui", fixture, candidate, preserved], True, umask=0o077)
    after = manifest(preserved)
    require(set(after) == set(before), "Preserve mode changed the bundle file set")
    for name in before:
        if name in {"Contents/MacOS/macbridge-mcp", "Contents/MacOS/macbridge-observer", "Contents/_CodeSignature/CodeResources"}:
            # Replaced core/signature bytes and sizes may differ, not entry type or permissions.
            require(after[name]["type"] == before[name]["type"] and after[name]["mode"] == before[name]["mode"], f"Preserve mode changed signed-file type or permissions: {name}")
        else:
            require(after[name] == before[name], f"Preserve mode changed resource: {name}")
    # cp replaces an existing regular file in the copied app, retaining that
    # destination's mode; bytes/size must match the candidate exactly.
    expected_core = dict(candidate_before, mode=before["Contents/MacOS/macbridge-mcp"]["mode"])
    require(after["Contents/MacOS/macbridge-mcp"] == expected_core, "Preserve mode did not keep the exact replacement core and expected metadata")

    raw_app_before = manifest(raw_app)
    case("raw-refuses-overwrite", [raw, raw_app], False)
    require(manifest(raw_app) == raw_app_before, "Refused raw overwrite changed app")
    preserved_before = manifest(preserved)
    case("preserve-refuses-overwrite", ["--preserve-ui", fixture, raw / "macbridge-mcp", preserved], False)
    require(manifest(preserved) == preserved_before, "Refused overwrite changed app")
    direct_child = fixture / "MacBridge.app"
    case("destination-direct-child-of-source", ["--preserve-ui", fixture, candidate, direct_child], False, direct_child)
    nested_child = fixture / "new-parent/deeper/MacBridge.app"
    # Alternate source spelling must not bypass directory-identity comparison.
    alternate_source = str(fixture.parent) + "/./MacBridge.app"
    case("destination-nested-inside-source", ["--preserve-ui", alternate_source, candidate, nested_child], False, nested_child)
    require(not (fixture / "new-parent").exists(), "Created a destination parent inside source app")
    require(manifest(fixture) == before, "Rejected nested destination changed source app")
    case("bad-arguments", [], False)
    missing = root / "missing" / "MacBridge.app"
    case("missing-raw-binaries", [root / "missing-input", missing], False, missing)
    case("missing-core", ["--preserve-ui", fixture, root / "no-core", missing], False, missing)
    case("missing-source-app", ["--preserve-ui", root / "no-source/MacBridge.app", raw / "macbridge-mcp", missing], False, missing)
    invalid_core = root / "invalid-core"
    invalid_core.write_bytes(b"Not executable software; invalid signature fixture.\n")
    invalid_core.chmod(0o700)
    case("unsigned-core", ["--preserve-ui", fixture, invalid_core, missing], False, missing)

    invalid_app = root / "invalid-source" / "MacBridge.app"
    shutil.copytree(fixture, invalid_app)
    with (invalid_app / "Contents/Info.plist").open("ab") as output:
        output.write(b"\n<!-- invalidates the existing bundle seal -->\n")
    case("invalid-source-seal", ["--preserve-ui", invalid_app, raw / "macbridge-mcp", missing], False, missing)
    extracted = root / "extracted"
    extracted.mkdir()
    shutil.copy2(raw / "macbridge-mcp", extracted / "macbridge-mcp")
    shutil.copy2(fixture / "Contents/MacOS/macbridge-observer", extracted / "macbridge-observer")
    case("extracted-bundle-ui-is-not-raw", [extracted, missing], False, missing)

    source_alias = root / "source-alias" / "MacBridge.app"
    source_alias.parent.mkdir()
    source_alias.symlink_to(fixture, target_is_directory=True)
    case("source-app-symlink", ["--preserve-ui", source_alias, raw / "macbridge-mcp", missing], False, missing)
    core_alias = root / "core-alias"
    core_alias.symlink_to(raw / "macbridge-mcp")
    case("core-symlink", ["--preserve-ui", fixture, core_alias, missing], False, missing)
    destination_alias = root / "dangling" / "MacBridge.app"
    destination_alias.parent.mkdir()
    destination_alias.symlink_to(root / "absent-target", target_is_directory=True)
    case("dangling-destination-symlink", [raw, destination_alias], False)
    require(destination_alias.is_symlink() and not (root / "absent-target").exists(), "Changed destination alias")
    real_parent = root / "real-parent"
    real_parent.mkdir()
    parent_alias = root / "parent-alias"
    parent_alias.symlink_to(real_parent, target_is_directory=True)
    case("destination-ancestor-symlink", [raw, parent_alias / "nested/MacBridge.app"], False)
    require(not list(real_parent.iterdir()), "Wrote through destination ancestor alias")
    case("dot-destination-component", [raw, str(root) + "/unused/../MacBridge.app"], False)
    # Swift commonly uses .build/release as a directory alias; keep that API usable.
    raw_alias = root / "release-alias"
    raw_alias.symlink_to(raw, target_is_directory=True)
    case("raw-directory-alias", [raw_alias, root / "alias-output/MacBridge.app"], True)

    require(manifest(source) == before and manifest(fixture) == before, "Packaging modified source app")
    require(all(entry_metadata(raw / name) == value for name, value in raw_before.items()), "Packaging modified raw input bytes or metadata")
    require(entry_metadata(candidate) == candidate_before, "Packaging modified replacement core input bytes or metadata")
    (root / "results.json").write_text(json.dumps({"checks": results, "manifest_self_checks": manifest_checks, "input_unchanged": True}, indent=2) + "\n")
    print(f"PASS: {len(results)} packaging cases and {len(manifest_checks)} manifest self-checks; input app and raw binary bytes/metadata unchanged")


if __name__ == "__main__":
    main()
