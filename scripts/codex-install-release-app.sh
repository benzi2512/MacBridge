#!/bin/sh
# Verify and optionally install the exact MacBridge v0.4.4 release app.
# This script performs no network access, privilege escalation, persistence,
# tunnel configuration, Gatekeeper change or credential access.
set -eu

fail() {
  echo "MacBridge install refused: $1" >&2
  exit "${2:-65}"
}

usage() {
  echo "usage: $0 /absolute/path/MacBridge-0.4.4-build8-macos-arm64-ad-hoc.zip [--install]" >&2
  exit 64
}

[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || usage
archive=$1
mode=verify
if [ "$#" -eq 2 ]; then
  [ "$2" = "--install" ] || usage
  mode=install
fi

case "$archive" in
  /*) ;;
  *) fail "archive path must be absolute" 64 ;;
esac

[ -f "$archive" ] && [ ! -L "$archive" ] || fail "archive must be a regular non-symlink file"
[ "$(/usr/bin/stat -f '%l' "$archive")" -eq 1 ] || fail "archive must have exactly one hard link"
[ "$(/usr/bin/uname -m)" = "arm64" ] || fail "this release supports Apple silicon only"
macos_version=$(/usr/bin/sw_vers -productVersion)
macos_major=${macos_version%%.*}
case "$macos_major" in
  ''|*[!0-9]*) fail "could not determine the macOS major version" ;;
esac
[ "$macos_major" -ge 13 ] || fail "this release requires macOS 13 or newer"

expected_archive=3e74c337d79451ea5807a300aaee8267232102bba2e9e17c06a5d69c5424e060
expected_core=38e4aeaad2608066ab712dd3dacbf20c71da79f8565667ea6048547e933dd13a
expected_observer=d8bdb6d44d22c437aa430d0d10dc841b80448fcc655f681fced7c5e6bc151986

actual_archive=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
[ "$actual_archive" = "$expected_archive" ] || fail "archive SHA-256 does not match the pinned v0.4.4 asset"
/usr/bin/zipinfo -1 "$archive" | /usr/bin/awk '
  /^\// || /^[A-Za-z]:/ || /(^|\/)\.\.(\/|$)/ || /\\/ { unsafe = 1 }
  END { exit unsafe ? 1 : 0 }
' || fail "archive contains an unsafe path"

umask 077
temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/macbridge-codex-install.XXXXXX")
staged_app=
staged_core=
staged_app_identity=
staged_core_identity=
installed_app=
installed_core=
installed_app_identity=
installed_core_identity=
path_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null || true
}
cleanup() {
  result=$?
  trap - EXIT HUP INT TERM
  if [ "$result" -ne 0 ]; then
    if [ -n "$installed_app" ] && [ -n "$installed_app_identity" ] \
       && [ "$(path_identity "$installed_app")" = "$installed_app_identity" ]; then
      /bin/rm -rf "$installed_app"
    fi
    if [ -n "$installed_core" ] && [ -n "$installed_core_identity" ] \
       && [ "$(path_identity "$installed_core")" = "$installed_core_identity" ]; then
      /bin/rm -f "$installed_core"
    fi
  fi
  if [ -n "$staged_app" ] && [ -n "$staged_app_identity" ] \
     && [ "$(path_identity "$staged_app")" = "$staged_app_identity" ]; then
    /bin/rm -rf "$staged_app"
  fi
  if [ -n "$staged_core" ] && [ -n "$staged_core_identity" ] \
     && [ "$(path_identity "$staged_core")" = "$staged_core_identity" ]; then
    /bin/rm -f "$staged_core"
  fi
  /bin/rm -rf "$temporary"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

/usr/bin/ditto -x -k "$archive" "$temporary/extracted"
app="$temporary/extracted/MacBridge.app"
[ -d "$app" ] && [ ! -L "$app" ] || fail "archive did not contain one MacBridge.app bundle"
[ -z "$(/usr/bin/find "$temporary/extracted" -mindepth 1 -maxdepth 1 ! -name MacBridge.app -print -quit)" ] || fail "archive contains unexpected top-level content"
[ -z "$(/usr/bin/find "$app" -type l -print -quit)" ] || fail "app bundle contains a symlink"

core="$app/Contents/MacOS/macbridge-mcp"
observer="$app/Contents/MacOS/macbridge-observer"
[ -f "$core" ] && [ -x "$core" ] && [ ! -L "$core" ] || fail "missing or unsafe core binary"
[ -f "$observer" ] && [ -x "$observer" ] && [ ! -L "$observer" ] || fail "missing or unsafe observer binary"

actual_core=$(/usr/bin/shasum -a 256 "$core" | /usr/bin/awk '{print $1}')
actual_observer=$(/usr/bin/shasum -a 256 "$observer" | /usr/bin/awk '{print $1}')
[ "$actual_core" = "$expected_core" ] || fail "embedded core SHA-256 mismatch"
[ "$actual_observer" = "$expected_observer" ] || fail "embedded observer SHA-256 mismatch"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[ "$version" = "0.4.4" ] && [ "$build" = "8" ] || fail "unexpected app version/build"
/usr/bin/file "$core" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64' || fail "core is not an arm64 Mach-O executable"
/usr/bin/file "$observer" | /usr/bin/grep -q 'Mach-O 64-bit executable arm64' || fail "observer is not an arm64 Mach-O executable"
/usr/bin/codesign --verify --deep --strict "$app" || fail "deep/strict code-signature verification failed"

echo "MacBridge release verification PASS"
echo "version=$version build=$build"
echo "archive_sha256=$actual_archive"
echo "core_sha256=$actual_core"
echo "observer_sha256=$actual_observer"

[ "$mode" = install ] || exit 0

[ -n "${HOME:-}" ] && [ "$HOME" != / ] || fail "HOME is unavailable or unsafe"
install_home=${MACBRIDGE_INSTALL_HOME:-$HOME}
case "$install_home" in
  /) fail "installation home cannot be the filesystem root" ;;
  /*) ;;
  *) fail "installation home must be absolute" ;;
esac
[ -d "$install_home" ] && [ ! -L "$install_home" ] || fail "installation home must be an existing non-symlink directory"
applications="$install_home/Applications"
local_root="$install_home/.local"
local_bin="$local_root/bin"
if [ -e "$applications" ] || [ -L "$applications" ]; then
  [ -d "$applications" ] && [ ! -L "$applications" ] || fail "Applications destination is unsafe"
fi
if [ -e "$local_root" ] || [ -L "$local_root" ]; then
  [ -d "$local_root" ] && [ ! -L "$local_root" ] || fail ".local destination is unsafe"
fi
if [ -e "$local_bin" ] || [ -L "$local_bin" ]; then
  [ -d "$local_bin" ] && [ ! -L "$local_bin" ] || fail ".local/bin destination is unsafe"
fi
destination_app="$applications/MacBridge.app"
destination_core="$local_bin/macbridge-mcp"
[ ! -e "$destination_app" ] && [ ! -L "$destination_app" ] || fail "MacBridge.app already exists; this fresh installer does not overwrite"
[ ! -e "$destination_core" ] && [ ! -L "$destination_core" ] || fail "macbridge-mcp already exists; this fresh installer does not overwrite"

/bin/mkdir -p "$applications" "$local_bin"
staged_app=$(/usr/bin/mktemp -d "$applications/.MacBridge.app.installing.XXXXXX")
staged_app_identity=$(path_identity "$staged_app")
[ -n "$staged_app_identity" ] || fail "could not identify the reserved app staging directory"
staged_core=$(/usr/bin/mktemp "$local_bin/.macbridge-mcp.installing.XXXXXX")
staged_core_identity=$(path_identity "$staged_core")
[ -n "$staged_core_identity" ] || fail "could not identify the reserved core staging file"

/usr/bin/ditto "$app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app" || fail "staged app signature verification failed"
[ "$(/usr/bin/shasum -a 256 "$staged_app/Contents/MacOS/macbridge-mcp" | /usr/bin/awk '{print $1}')" = "$expected_core" ] || fail "staged app core changed"

/bin/cp "$core" "$staged_core"
/bin/chmod 755 "$staged_core"
[ "$(/usr/bin/shasum -a 256 "$staged_core" | /usr/bin/awk '{print $1}')" = "$expected_core" ] || fail "staged headless core changed"

/bin/mkdir "$destination_app" 2>/dev/null || fail "MacBridge.app destination became occupied; nothing was overwritten"
installed_app=$destination_app
installed_app_identity=$(path_identity "$installed_app")
[ -n "$installed_app_identity" ] || fail "could not identify the reserved app destination"
/usr/bin/ditto "$staged_app/" "$destination_app/"
/bin/chmod "$(/usr/bin/stat -f '%Lp' "$app")" "$destination_app"

/bin/link "$staged_core" "$destination_core" 2>/dev/null \
  || fail "macbridge-mcp destination became occupied; nothing was overwritten"
installed_core=$destination_core
installed_core_identity=$staged_core_identity
[ "$(path_identity "$installed_core")" = "$installed_core_identity" ] || fail "installed core identity changed during publication"

/usr/bin/codesign --verify --deep --strict "$destination_app" || fail "installed app signature verification failed"
[ "$(/usr/bin/shasum -a 256 "$destination_core" | /usr/bin/awk '{print $1}')" = "$expected_core" ] || fail "installed core verification failed"

/bin/rm -rf "$staged_app"
staged_app=
/bin/rm -f "$staged_core"
staged_core=
staged_app_identity=
staged_core_identity=
installed_app=
installed_core=
installed_app_identity=
installed_core_identity=

echo "MacBridge local install PASS"
echo "app=$destination_app"
echo "core=$destination_core"
echo "Next: follow CODEX-SETUP.md to create this user's private tunnel and ChatGPT connection."
