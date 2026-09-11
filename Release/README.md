# Release privacy checks

`privacy_gate.py` is a local, standard-library-only, read-only inspection tool.
It neither downloads dependencies nor executes input files, uploads data, changes
Git refs, installs software, grants permissions or publishes a repository.

Run it against a separately staged export, not a live home or runtime directory:

```sh
python3 -B Release/privacy_gate.py tree /absolute/staged-source \
  --markers /absolute/private-review/markers.txt \
  --report /absolute/private-review/source-report.json
python3 -B Release/privacy_gate.py git /absolute/repository \
  --revision FULL_IMMUTABLE_COMMIT_SHA \
  --markers /absolute/private-review/markers.txt \
  --report /absolute/private-review/history-report.json
```

Marker files contain one private identifier per line and **must remain outside
the export and repository**. Do not put an owner's name, account address, business
name, home directory or secret in shared test fixtures or a shared denylist.
Reports contain rule identifiers and redacted locations, never matched values.
They refuse overwriting an existing report.

Location redaction covers all built-in detection rules as well as explicit
markers, home usernames and email addresses. It matches the original location
before replacing overlapping spans, so a marker cannot partially unmask a
credential. The same redacted records are used in console and file reports.

Match processing preserves first-occurrence order and line numbers without
repeated full-prefix scans. At most 10,000 distinct issues are retained, plus
the fixed incomplete-scan sentinel. Exceeding this budget yields `blocked`,
`complete: false` and `issues_truncated: true`; it is never a clean scan.
Repeated matches on the same line do not consume additional issue slots.
The cap limits diagnostics, not permission to discard remaining evidence and
publish. The report's `issue_limit` field states the configured bound.

The tree check does not follow links. It flags generated caches, configuration and
credential filenames, opaque archives, private paths, non-example emails, common
credential formats, private-chat URLs and configured private identifiers. It
checks raw and UTF-16 representations. Directory traversal is descriptor-relative
and refuses changed entries. Read errors, oversized inputs and budget limits
fail closed. Git mode checks all reachable objects, including deleted historical
blobs and commit metadata, from one full immutable commit. Shallow histories,
missing objects, links and submodules cannot silently pass.

Before publication, separately verify **every remote branch/tag**, the exact
staged source, the final built app and the final DMG contents. This tool does not
prove absence of encoded or semantically private information. An archive hit is
a requirement for separate non-executing inspection, not a reason to skip it.
A clear report is not permission to install, sign, upload or switch visibility.

Keep the report, private markers and build caches outside the release. Preserve
the audited source digest and exact final binary/artifact hashes. Never treat
successful ad-hoc signing as Developer ID verification or notarization.

Synthetic test suite:

```sh
cd Release
python3 -B -m unittest -v test_privacy_gate
```

Tests create and remove only their own temporary fixtures; Git tests use local
repositories with disabled hooks/signing and synthetic identities. No provider
API or production configuration is used. Review executable test code and use
network-denied isolation before execution.
# Development DMG and first-run checks

`package_dmg.py` uses only already-built, reviewed arm64 binaries. Both exact
SHA-256 digests are required. It accepts no existing app bundle and copies only
the core, observer, reviewed Info.plist, canonical PNG/ICNS, the first-run
guide and the CodeNotch MIT notice as `Resources/ThirdPartyNotices.txt`.
The notice is required and bound into the payload manifest and app signature.
Extended metadata from source files is not copied. Quarantined inputs
are refused, never stripped to bypass a security decision.

The destination must be a new canonical directory ending in `.noindex`, outside
source. The packager does not overwrite prior runs. App assembly happens in a
fresh `/private/tmp/*.noindex` staging directory, away from file-provider folders
that can inject Finder metadata and invalidate signing. No metadata or macOS
security check is disabled to work around that condition. It signs only its newly
created app ad hoc, scans payload bytes, creates a non-indexed compressed DMG,
mounts it read-only, compares every expected file and directory, verifies the
signature, scans again, and detaches its own mount. No app is installed or
launched; no tunnel or service is provisioned. Only the verified DMG and receipt
are byte-copied to the requested destination; staging and its local path stay
out of the public receipt. Failed outputs remain available
for inspection. No unknown directory is recursively removed.

Use a release build, not debug binaries containing private machine paths. With
the existing Swift toolchain, remap the exact local source/build prefixes using
`-file-prefix-map` and `-debug-prefix-map`, set a non-private
`-file-compilation-dir`, and disable debug information with `-gnone`. Keep build
scratch/caches outside exported source, disable automatic dependency resolution
and credential helpers, and review Package.swift before execution. This source
declares no external Swift package dependencies. Inspect the linked libraries
and exact payload after building; flags alone are not privacy evidence.

```sh
python3 -B Release/package_dmg.py \
  --binary-directory /absolute/reviewed/release \
  --core-sha256 EXACT_64_CHARACTER_CORE_SHA256 \
  --ui-sha256 EXACT_64_CHARACTER_UI_SHA256 \
  --output /absolute/new/distribution.noindex \
  --private-markers /absolute/private/markers.txt
```

The result is explicitly `development_image_verified`, with
`distribution_ready: false`. Ad-hoc signing cannot prove publisher identity or
replace notarization. Developer ID signing, clean-machine onboarding, reboot,
normal-Chat acceptance and public-history privacy remain separate release gates.
Do not remove quarantine or disable Gatekeeper to manufacture acceptance.

Synthetic packaging guards can run with networking disabled and writes limited
to their own `/private/tmp` fixtures:

```sh
cd Release
python3 -B -m unittest -v test_privacy_gate test_package_dmg
```

Native disk-image creation explicitly keeps source-volume ownership unchanged
(`-srcowners any`); it never changes ownership settings on the source disk.
