#!/bin/bash
# Regression test for the release-time changelog scripts, run in the order
# .github/workflows/release.yml runs them: extract-changelog.sh (release notes)
# → promote-changelog.sh (which runs changelog-rollover.py). Works on copies of
# the real CHANGELOG.md and docs/changelog/, for patch and minor releases, with
# and without [Unreleased] entries. Usage: scripts/test-changelog-release.sh

set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILURES=0

fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# Every changelog file in the working copy; docs/changelog/ may not exist yet.
changelogs() { ls CHANGELOG.md docs/changelog/*.md 2>/dev/null || true; }

# Version numbers derived from the newest release, so the test keeps working after releases.
LATEST=$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | tr -d '#[] ')
IFS=. read -r MAJOR MINOR PATCH <<< "$LATEST"
NEXT_PATCH="$MAJOR.$MINOR.$((PATCH + 1))"
NEXT_MINOR="$MAJOR.$((MINOR + 1)).0"

run_case() {
    local version=$1 empty_unreleased=$2 expect_rollover=$3
    echo "case: release $version (latest $LATEST), empty [Unreleased]: $empty_unreleased"

    local dir; dir=$(mktemp -d)
    mkdir -p "$dir/scripts" "$dir/docs"
    cp "$ROOT/CHANGELOG.md" "$dir/"
    if [ -d "$ROOT/docs/changelog" ]; then cp -r "$ROOT/docs/changelog" "$dir/docs/"; fi
    cp "$ROOT"/scripts/{extract-changelog.sh,promote-changelog.sh,changelog-rollover.py} "$dir/scripts/"
    cd "$dir"

    # [Unreleased] holds a curated entry, or nothing at all.
    python3 - "$empty_unreleased" <<'PY'
import sys
s = open("CHANGELOG.md").read()
a = s.index("## [Unreleased]") + len("## [Unreleased]")
b = s.index("\n---", a)
entry = "" if sys.argv[1] == "yes" else "\n### Fixed\n- The menu bar keeps streaming. ([#1](https://example.com/1))\n"
open("CHANGELOG.md", "w").write(s[:a] + "\n" + entry + s[b:])
PY
    changelogs | xargs cat > before.md
    local headings_before; headings_before=$(changelogs | xargs cat | grep -c '^## \[')

    # Release notes are extracted before promotion, from [Unreleased]
    local notes; notes=$(./scripts/extract-changelog.sh "$version" 2>/dev/null || true)
    if [ "$empty_unreleased" = yes ]; then
        [ -z "$notes" ] || fail "empty [Unreleased] produced notes, so the workflow won't fall back to generated ones"
    else
        grep -q 'keeps streaming' <<< "$notes" || fail "release notes miss the [Unreleased] entry"
        grep -qx -- '---' <<< "$notes" && fail "release notes include the section separator"
    fi

    ./scripts/promote-changelog.sh "$version" 2026-01-01 > /dev/null

    # [Unreleased] is reset and the new version sits right below it
    [ "$(grep -m2 '^## \[' CHANGELOG.md | tail -1)" = "## [$version] - 2026-01-01" ] || fail "new version is not the first release"
    grep -q "^\[$version\]: " CHANGELOG.md || fail "no compare link for $version"

    # The promoted section extracts cleanly: only its own entries
    if [ "$empty_unreleased" = no ]; then
        local promoted; promoted=$(./scripts/extract-changelog.sh "$version")
        [ "$promoted" = "$notes" ] || fail "notes after promotion differ from notes before it"
        grep -q 'Older releases' <<< "$promoted" && fail "notes include the 'Older releases' line"
        grep -qE '^\[[^]]+\]: ' <<< "$promoted" && fail "notes include reference links"
    fi

    # Only the current minor stays in CHANGELOG.md
    local minors; minors=$(grep -oE '^## \[[0-9]+\.[0-9]+' CHANGELOG.md | sort -u | wc -l | tr -d ' ')
    [ "$minors" = 1 ] || fail "CHANGELOG.md holds $minors minors"
    if [ "$expect_rollover" = yes ]; then
        [ -f "docs/changelog/$MAJOR.$MINOR.md" ] || fail "previous minor not archived to docs/changelog/$MAJOR.$MINOR.md"
        grep -q "(docs/changelog/$MAJOR.$MINOR.md)" CHANGELOG.md || fail "no 'Older releases' link to the new archive"
    else
        [ -f "docs/changelog/$MAJOR.$MINOR.md" ] && fail "patch release archived the current minor"
    fi

    # Nothing lost: every release heading still exists, plus the new one
    local headings_after; headings_after=$(changelogs | xargs cat | grep -c '^## \[')
    [ "$headings_after" = $((headings_before + 1)) ] || fail "release headings $headings_before → $headings_after (expected +1)"

    # Nothing lost: every line from before the release is still in some file
    local lost; lost=$(python3 - "$dir/before.md" <<'PY'
import sys, glob
before = [l.replace("](../../", "](") for l in open(sys.argv[1]).read().splitlines()]
after = set()
for f in ["CHANGELOG.md"] + glob.glob("docs/changelog/*.md"):
    after |= {l.replace("](../../", "](") for l in open(f).read().splitlines()}
skip = ("## [Unreleased]", "## Older releases", "[Unreleased]: ", "---")
for l in before:
    if l.strip() and not l.startswith(skip) and "](docs/changelog/" not in l and l not in after:
        print(l)
PY
)
    [ -z "$lost" ] || fail "lines lost: $(head -1 <<< "$lost")"

    # Archived relative links resolve from docs/changelog/
    local broken; broken=$({ grep -ohE '\]\(\.\./\.\./[^)#]+' docs/changelog/*.md 2>/dev/null || true; } | sed 's|^](\.\./\.\./||' | sort -u \
        | while read -r p; do [ -e "$ROOT/$p" ] || echo "$p"; done)
    [ -z "$broken" ] || fail "archived links don't resolve: $broken"

    # Rollover is idempotent
    local before; before=$(changelogs | xargs cat | shasum)
    python3 scripts/changelog-rollover.py CHANGELOG.md
    [ "$before" = "$(changelogs | xargs cat | shasum)" ] || fail "rollover changed files on a second run"

    cd "$ROOT"; rm -rf "$dir"
}

run_case "$NEXT_PATCH" no no
run_case "$NEXT_PATCH" yes no
run_case "$NEXT_MINOR" no yes
run_case "$NEXT_MINOR" yes yes

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES failure(s)"
    exit 1
fi
echo "all changelog release cases pass"
