#!/usr/bin/env bash
# scripts/release.sh — decide the next version from CHANGELOG.md and apply it.
#
# The `## Unreleased` section is the release's input. Its `###` headings say
# how far the version moves:
#
#   ### Breaking   → major
#   ### Added      → minor
#   anything else  → patch      (### Changed, ### Fixed, or loose bullets)
#   empty          → patch      (a lockstep bump: the note says so)
#
# Usage:
#   scripts/release.sh --bump auto|major|minor|patch [--version <x.y.z>]
#        [--app-sha <sha>] [--changed true|false]
#        [--notes-out <file>] [--dry-run]
#   scripts/release.sh --notes-for <version> [--notes-out <file>]
#        (print the changelog entry of an already-bumped version; used when a
#         previous run merged the bump but failed before releasing)
#
# What it writes (unless --dry-run): CHANGELOG.md (Unreleased → the new
# version, dated), Revnix.podspec's s.version, and RevnixClient.sdkVersion.
# In Actions it sets current / next / level / lockstep / summary on
# $GITHUB_OUTPUT.
#
# Unlike the npm SDKs there is no registry to publish to: for Swift Package
# Manager the git tag *is* the release, so the workflow tags what this script
# bumped.

set -euo pipefail

PODSPEC="Revnix.podspec"
SOURCE="Sources/Revnix/RevnixClient.swift"
CHANGELOG="CHANGELOG.md"

bump="auto"
wanted=""
app_sha=""
changed=""
notes_out=""
notes_for=""
dry_run=""

while [ $# -gt 0 ]; do
  case "$1" in
    --bump) bump="$2"; shift 2 ;;
    --version) wanted="$2"; shift 2 ;;
    --app-sha) app_sha="$2"; shift 2 ;;
    --changed) changed="$2"; shift 2 ;;
    --notes-out) notes_out="$2"; shift 2 ;;
    --notes-for) notes_for="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "release.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done

fail() { echo "release.sh: $*" >&2; exit 1; }

# Print the body of a "## <version>" entry, stopping at the next "## ".
entry_for() {
  awk -v want="## $1" '
    $0 == want { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' "$CHANGELOG" | sed -e '/./,$!d' | awk 'BEGIN { blank = 0 }
    /^[[:space:]]*$/ { blank++; next }
    { while (blank-- > 0) print ""; blank = 0; print }'
}

# --notes-for: an earlier run already bumped and landed; just re-read its entry.
if [ -n "$notes_for" ]; then
  [ -f "$CHANGELOG" ] || fail "no $CHANGELOG"
  # The dated heading is "## X.Y.Z (YYYY-MM-DD)", so match on the prefix.
  heading=$(grep -m1 "^## $notes_for\( \|$\)" "$CHANGELOG" || true)
  [ -n "$heading" ] || fail "$CHANGELOG has no \"## $notes_for\" entry"
  body=$(entry_for "${heading#\#\# }")
  [ -n "$notes_out" ] && printf '%s\n' "$body" > "$notes_out"
  printf '%s\n' "$body"
  exit 0
fi

case "$bump" in
  auto|major|minor|patch) ;;
  *) fail "--bump must be auto|major|minor|patch, got $bump" ;;
esac
if [ -n "$wanted" ]; then
  echo "$wanted" | grep -qE '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail "--version must be x.y.z, got $wanted"
fi

[ -f "$PODSPEC" ] || fail "no $PODSPEC"
[ -f "$SOURCE" ] || fail "no $SOURCE"
[ -f "$CHANGELOG" ] || fail "no $CHANGELOG"

current=$(sed -n "s/^[[:space:]]*s\.version[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$PODSPEC")
[ -n "$current" ] || fail "could not read s.version from $PODSPEC"
echo "$current" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "$PODSPEC version $current is not x.y.z"

# The source constant must already agree with the podspec, or the bump would
# silently paper over a drift that shipped in the last release.
source_version=$(sed -n 's/.*static let sdkVersion = "\([^"]*\)".*/\1/p' "$SOURCE")
[ "$source_version" = "$current" ] \
  || fail "$SOURCE says $source_version but $PODSPEC says $current — reconcile them first"

unreleased=$(entry_for "Unreleased")

count_under() {
  printf '%s\n' "$unreleased" | awk -v want="### $1" '
    $0 ~ "^### " { active = ($0 == want); next }
    active && /^[[:space:]]*-/ { n++ }
    END { print n + 0 }'
}
total_bullets=$(printf '%s\n' "$unreleased" | grep -cE '^[[:space:]]*-' || true)
breaking=$(count_under "Breaking")
added=$(count_under "Added")

if [ "$bump" != "auto" ]; then
  level="$bump"
elif [ "$breaking" -gt 0 ]; then
  level="major"
elif [ "$added" -gt 0 ]; then
  level="minor"
else
  level="patch"
fi

major=${current%%.*}
rest=${current#*.}
minor=${rest%%.*}
patch=${rest#*.}
case "$level" in
  major) next="$((major + 1)).0.0" ;;
  minor) next="$major.$((minor + 1)).0" ;;
  patch) next="$major.$minor.$((patch + 1))" ;;
esac

if [ -n "$wanted" ]; then
  highest=$(printf '%s\n%s\n' "$current" "$wanted" | sort -V | tail -1)
  [ "$wanted" != "$current" ] && [ "$highest" = "$wanted" ] \
    || fail "--version $wanted is not above $current"
  IFS=. read -r wmajor wminor _ <<< "$wanted"
  if [ "$wmajor" != "$major" ]; then level="major"
  elif [ "$wminor" != "$minor" ]; then level="minor"
  else level="patch"; fi
  next="$wanted"
fi

# A release with nothing recorded under Unreleased is a lockstep bump: the
# SDKs track revnix-app releases even when their own code did not move.
lockstep=false
body=$(printf '%s\n' "$unreleased" | sed -e '/./,$!d')
if [ "$total_bullets" -eq 0 ]; then
  lockstep=true
  if [ "$changed" = "true" ]; then
    body="Changes since $current were not recorded here; see the commit log."
  else
    ride=""
    [ -n "$app_sha" ] && ride=" ${app_sha:0:7}"
    body="No SDK changes. Version moved in lockstep with revnix-app release${ride}; the package contents are identical to $current."
  fi
fi

today=$(date -u +%Y-%m-%d)
summary="$level bump, ${total_bullets} changelog bullet(s), lockstep=$lockstep"

if [ -n "$notes_out" ]; then
  printf '%s\n' "$body" > "$notes_out"
fi

if [ -z "$dry_run" ]; then
  # CHANGELOG: turn Unreleased into the dated entry, leave a fresh Unreleased.
  tmp=$(mktemp)
  {
    awk '/^## Unreleased/ { exit } { print }' "$CHANGELOG"
    printf '## Unreleased\n\n## %s (%s)\n\n' "$next" "$today"
    printf '%s\n\n' "$body"
    awk 'skip { print } /^## Unreleased/ { skip = 1; next }' "$CHANGELOG" \
      | awk 'found { print } /^## / { found = 1; print }'
  } > "$tmp"
  mv "$tmp" "$CHANGELOG"

  # Version lives in two files; both move together or the release is a lie.
  perl -0pi -e "s/(s\.version\s*=\s*')[^']*(')/\${1}$next\${2}/" "$PODSPEC"
  perl -0pi -e "s/(static let sdkVersion = \")[^\"]*(\")/\${1}$next\${2}/" "$SOURCE"
fi

echo "$current -> $next ($summary)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "current=$current"
    echo "next=$next"
    echo "level=$level"
    echo "lockstep=$lockstep"
    echo "summary=$summary"
  } >> "$GITHUB_OUTPUT"
fi
