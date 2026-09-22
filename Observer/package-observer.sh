#!/bin/sh
# Packages only already-built local binaries. No build, download or installation.
set -eu
fail() { echo "$1" >&2; exit "${2:-65}"; }
usage() {
  echo "usage: package-observer.sh /absolute/binary-directory /absolute/new/MacBridge.app" >&2
  echo "   or: package-observer.sh --preserve-ui /absolute/source/MacBridge.app /absolute/candidate-mcp /absolute/new/MacBridge.app" >&2
  exit 64
}
mode=raw
source_app=
if [ "$#" -eq 2 ]; then
  case "$1" in /*) ;; *) usage ;; esac
  core="$1/macbridge-mcp"
  observer="$1/macbridge-observer"
  destination=$2
elif [ "$#" -eq 4 ] && [ "$1" = "--preserve-ui" ]; then
  mode=preserve
  source_app=$2
  core=$3
  observer="$source_app/Contents/MacOS/macbridge-observer"
  destination=$4
  case "$source_app" in /*/MacBridge.app) ;; *) usage ;; esac
else
  usage
fi
case "$core" in /*) ;; *) usage ;; esac
case "$destination" in /*/MacBridge.app) ;; *) usage ;; esac
case "$destination/" in */../*|*/./*) fail "Destination must not contain dot path components" 64 ;; esac
# Inspect every existing destination component, including dangling symlinks.
# Swift's .build/release input alias remains supported by the original API.
component=$destination
while [ "$component" != / ]; do
  [ ! -L "$component" ] || fail "Refusing a symlink destination or ancestor" 73
  # Compare directory identity, not path spelling, so aliases/case cannot make
  # ditto copy an app into itself or create new directories inside the source.
  if [ "$mode" = preserve ] && [ -d "$component" ] && [ "$component" -ef "$source_app" ]; then
    fail "Destination must be outside the source app" 73
  fi
  component=$(dirname -- "$component")
done
if [ -e "$destination" ]; then fail "Refusing to overwrite existing app" 73; fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for binary in "$core" "$observer"; do
  [ -f "$binary" ] && [ -x "$binary" ] && [ ! -L "$binary" ] || fail "Missing, non-executable or symlink binary: $binary"
done
/usr/bin/codesign --verify --strict "$core"
core_hash=$(/usr/bin/shasum -a 256 "$core" | /usr/bin/awk '{print $1}')
if [ "$mode" = preserve ]; then
  [ -d "$source_app" ] && [ ! -L "$source_app" ] || fail "Source app must be a real directory"
  [ -z "$(/usr/bin/find "$source_app" -type l -print)" ] || fail "Source app must not contain symlinks"
  /usr/bin/codesign --verify --deep --strict "$source_app"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_app/Contents/Info.plist")" = macbridge-observer ] || fail "Source app has an unexpected main executable"
  source_app_mode=$(/usr/bin/stat -f '%Mp%03Lp' "$source_app")
  observer_hash=$(/usr/bin/shasum -a 256 "$observer" | /usr/bin/awk '{print $1}')
else
  /usr/bin/codesign --verify --strict "$observer"
  [ -f "$script_dir/Info.plist" ] &&
    [ -f "$script_dir/../Assets/Brand/macbridge-icon.png" ] &&
    [ -f "$script_dir/../Assets/Brand/MacBridge.icns" ] &&
    [ -f "$script_dir/CODENOTCH-LICENSE.txt" ] || fail "Missing local bundle resources"
fi
/bin/mkdir -p "$(dirname -- "$destination")"
# Reserve a new directory, rather than allowing a copy command to overwrite one.
/bin/mkdir "$destination"
if [ "$mode" = preserve ]; then
  /usr/bin/ditto "$source_app" "$destination"
  # ditto retains an existing destination root's mode. Restore only this new
  # root from the source; keep the caller's restrictive umask unchanged.
  /bin/chmod "$source_app_mode" "$destination"
  /usr/bin/codesign --verify --deep --strict "$destination"
  [ "$observer_hash" = "$(/usr/bin/shasum -a 256 "$destination/Contents/MacOS/macbridge-observer" | /usr/bin/awk '{print $1}')" ] || fail "Source UI changed during copy"
else
  /bin/mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources"
  /bin/cp "$observer" "$destination/Contents/MacOS/macbridge-observer"
  /bin/cp "$script_dir/Info.plist" "$destination/Contents/Info.plist"
  /bin/cp "$script_dir/../Assets/Brand/macbridge-icon.png" "$destination/Contents/Resources/MacBridge.png"
  /bin/cp "$script_dir/../Assets/Brand/MacBridge.icns" "$destination/Contents/Resources/MacBridge.icns"
  /bin/cp "$script_dir/CODENOTCH-LICENSE.txt" "$destination/Contents/Resources/ThirdPartyNotices.txt"
fi
/bin/cp "$core" "$destination/Contents/MacOS/macbridge-mcp"
[ "$core_hash" = "$(/usr/bin/shasum -a 256 "$destination/Contents/MacOS/macbridge-mcp" | /usr/bin/awk '{print $1}')" ] || fail "Candidate core changed during copy"
# Finder/file-provider folders can add cosmetic resource metadata to a newly
# created bundle. Remove only the two attributes rejected by codesign; retain
# provenance, quarantine and every other security-relevant attribute.
/usr/bin/xattr -dr com.apple.FinderInfo "$destination" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$destination" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$destination"
/usr/bin/codesign --verify --deep --strict "$destination"
[ "$core_hash" = "$(/usr/bin/shasum -a 256 "$destination/Contents/MacOS/macbridge-mcp" | /usr/bin/awk '{print $1}')" ] || fail "Packaging changed the candidate core"
/usr/bin/shasum -a 256 "$destination/Contents/MacOS/macbridge-mcp" "$destination/Contents/MacOS/macbridge-observer"
