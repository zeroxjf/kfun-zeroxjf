#!/usr/bin/env bash
# Build, optionally commit + push, and publish the resulting IPA as a
# GitHub Release.
#
# Usage:
#   ./scripts/release.sh                                # auto-bump patch, auto-commit, push, build, release
#   ./scripts/release.sh "commit message"               # auto-bump patch + commit msg, push, build, release
#   ./scripts/release.sh "commit message" "release notes"   # custom notes for the GH Release
#   NOTES_FILE=NOTES.md ./scripts/release.sh "..."      # read notes from a file
#   BUMP=minor ./scripts/release.sh "..."               # bump minor (1.0.14 -> 1.1.0)
#   BUMP=major ./scripts/release.sh "..."               # bump major (1.0.14 -> 2.0.0)
#   BUMP=none  ./scripts/release.sh "..."               # leave MARKETING_VERSION as-is
#   VERSION=1.5.3 ./scripts/release.sh "..."            # set an explicit version
#   TAG=v1.2.3 ./scripts/release.sh "..."               # override tag (defaults to v${VERSION})
#
# The release script owns versioning end-to-end: it edits MARKETING_VERSION and
# CURRENT_PROJECT_VERSION in the xcodeproj, commits the bump (along with any
# other working-tree changes), pushes, builds, and tags. The compiled
# CFBundleShortVersionString, CFBundleVersion, the IPA filename, and the GitHub
# release tag all flow from the bumped version.
#
# Release notes default to the commit *subject only* (first line) — so the
# Releases page stays terse. Pass a second arg or NOTES_FILE for a richer
# changelog.
#
# Requires: git, gh (authenticated), xcodebuild.

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v gh >/dev/null; then
    echo "error: gh CLI not installed (brew install gh)" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh not authenticated (gh auth login)" >&2
    exit 1
fi

MSG="${1:-}"
NOTES_ARG="${2:-}"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
PBXPROJ="Cyanide.xcodeproj/project.pbxproj"

# --- versioning -------------------------------------------------------------

current_marketing_version() {
    grep -m1 "MARKETING_VERSION" "$PBXPROJ" \
        | sed -E 's/.*MARKETING_VERSION = ([0-9.]+);.*/\1/'
}

set_marketing_version() {
    local new="$1"
    # macOS sed needs the empty-string -i argument.
    sed -i '' -E "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${new};/g" "$PBXPROJ"
}

current_build_version() {
    grep -m1 "CURRENT_PROJECT_VERSION" "$PBXPROJ" \
        | sed -E 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/'
}

set_build_version() {
    local new="$1"
    # macOS sed needs the empty-string -i argument.
    sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${new};/g" "$PBXPROJ"
}

build_version_for_marketing_version() {
    local version="$1"
    local major minor patch
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    patch=$(echo "$version" | cut -d. -f3)
    [ -z "$major" ] && major=0
    [ -z "$minor" ] && minor=0
    [ -z "$patch" ] && patch=0
    echo $((major * 1000000 + minor * 1000 + patch))
}

compute_new_version() {
    local current="$1"
    if [ -n "${VERSION:-}" ]; then
        echo "$VERSION"
        return
    fi
    local bump="${BUMP:-patch}"
    if [ "$bump" = "none" ]; then
        echo "$current"
        return
    fi
    local major minor patch
    major=$(echo "$current" | cut -d. -f1)
    minor=$(echo "$current" | cut -d. -f2)
    patch=$(echo "$current" | cut -d. -f3)
    [ -z "$minor" ] && minor=0
    [ -z "$patch" ] && patch=0
    case "$bump" in
        patch) patch=$((patch + 1)) ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        major) major=$((major + 1)); minor=0; patch=0 ;;
        *)
            echo "error: unknown BUMP=$bump (use patch|minor|major|none)" >&2
            exit 1
            ;;
    esac
    echo "${major}.${minor}.${patch}"
}

# Snapshot dirty state *before* the bump so we can tell apart bump-only commits
# (auto-message OK) vs. mixed commits (user-supplied message required).
TREE_WAS_DIRTY=0
if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    TREE_WAS_DIRTY=1
fi

CURRENT_VERSION=$(current_marketing_version)
if [ -z "$CURRENT_VERSION" ]; then
    echo "error: could not parse MARKETING_VERSION from $PBXPROJ" >&2
    exit 1
fi
NEW_VERSION=$(compute_new_version "$CURRENT_VERSION")
CURRENT_BUILD_VERSION=$(current_build_version)
if [ -z "$CURRENT_BUILD_VERSION" ]; then
    echo "error: could not parse CURRENT_PROJECT_VERSION from $PBXPROJ" >&2
    exit 1
fi
NEW_BUILD_VERSION=$(build_version_for_marketing_version "$NEW_VERSION")

BUMPED=0
if [ "$NEW_VERSION" != "$CURRENT_VERSION" ]; then
    echo "==> bumping MARKETING_VERSION: $CURRENT_VERSION -> $NEW_VERSION"
    set_marketing_version "$NEW_VERSION"
    BUMPED=1
else
    echo "==> MARKETING_VERSION unchanged at $CURRENT_VERSION"
fi
if [ "$NEW_BUILD_VERSION" != "$CURRENT_BUILD_VERSION" ]; then
    echo "==> bumping CURRENT_PROJECT_VERSION: $CURRENT_BUILD_VERSION -> $NEW_BUILD_VERSION"
    set_build_version "$NEW_BUILD_VERSION"
    BUMPED=1
else
    echo "==> CURRENT_PROJECT_VERSION unchanged at $CURRENT_BUILD_VERSION"
fi

# 1. Build the IPA against the newly resolved MARKETING_VERSION and
#    CURRENT_PROJECT_VERSION. build.sh writes build/Cyanide-${VERSION}.ipa and
#    refreshes a build/Cyanide.ipa symlink. We build *before* committing so the
#    actual IPA size can be baked into source.json in the same commit.
./scripts/build.sh

# Read bundle versions from the just-built app. CFBundleShortVersionString
# drives the IPA filename and tag; CFBundleVersion must advance too so iOS/Xcode
# never keeps a stale installed bundle around under the same internal build.
APP_PATH="$PWD/build/DerivedData/Build/Products/Debug-iphoneos/Cyanide.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from $APP_PATH/Info.plist" >&2
    exit 1
fi
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Info.plist" 2>/dev/null || true)
if [ -z "$BUILD_VERSION" ]; then
    echo "error: could not read CFBundleVersion from $APP_PATH/Info.plist" >&2
    exit 1
fi
if [ "$BUILD_VERSION" != "$NEW_BUILD_VERSION" ]; then
    echo "error: built CFBundleVersion=$BUILD_VERSION, expected $NEW_BUILD_VERSION" >&2
    exit 1
fi
echo "==> built bundle version: marketing=$VERSION build=$BUILD_VERSION"

IPA="$PWD/build/Cyanide-${VERSION}.ipa"
if [ ! -f "$IPA" ]; then
    echo "error: $IPA not found after build" >&2
    exit 1
fi
EFFECTIVE_TAG="${TAG:-v${VERSION}}"

# 2. Refresh source.json (AltSource manifest) so AltStore/SideStore clients
#    pull the new release automatically. Updates version, date, size,
#    downloadURL on apps[0].versions[0] of source.json at the repo root.
SOURCE_JSON="source.json"
if [ -f "$SOURCE_JSON" ]; then
    IPA_BYTES=$(stat -f%z "$IPA")
    ORIGIN_URL_FOR_JSON=$(git remote get-url origin 2>/dev/null || true)
    REPO_SLUG_FOR_JSON=$(echo "$ORIGIN_URL_FOR_JSON" \
        | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##' \
        | sed -E 's#\.git$##')
    DOWNLOAD_URL="https://github.com/${REPO_SLUG_FOR_JSON}/releases/download/${EFFECTIVE_TAG}/Cyanide-${VERSION}.ipa"
    RELEASE_DATE=$(date '+%Y-%m-%d')
    echo "==> refreshing $SOURCE_JSON: version=$VERSION size=$IPA_BYTES"
    python3 - <<PY
import json
path = "$SOURCE_JSON"
with open(path) as f:
    data = json.load(f)
ver = data["apps"][0]["versions"][0]
ver["version"]     = "$VERSION"
ver["date"]        = "$RELEASE_DATE"
ver["size"]        = $IPA_BYTES
ver["downloadURL"] = "$DOWNLOAD_URL"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
fi

# 3. Commit if there's anything to commit: pre-existing tree changes, the
#    MARKETING_VERSION bump, or the source.json refresh.
NEEDS_COMMIT=0
if [ "$TREE_WAS_DIRTY" = "1" ] || [ "$BUMPED" = "1" ]; then
    NEEDS_COMMIT=1
elif ! git diff-index --quiet HEAD --; then
    # source.json may have changed even when the version didn't, e.g. when
    # downloading and re-uploading the same TAG with a different binary.
    NEEDS_COMMIT=1
fi
if [ "$NEEDS_COMMIT" = "1" ]; then
    if [ -z "$MSG" ]; then
        if [ "$TREE_WAS_DIRTY" = "0" ] && [ "$BUMPED" = "1" ]; then
            MSG="Bump version to $NEW_VERSION"
            echo "==> auto-commit message: $MSG"
        elif [ "$TREE_WAS_DIRTY" = "0" ]; then
            MSG="Refresh source.json for $EFFECTIVE_TAG"
            echo "==> auto-commit message: $MSG"
        else
            echo "error: working tree has changes but no commit message was provided." >&2
            echo "       pass a message as the first arg, or stash changes." >&2
            exit 1
        fi
    fi
    echo "==> committing"
    git add -A
    git commit -m "$MSG"
fi

# 4. Push (no-op if already in sync).
echo "==> pushing $BRANCH"
git push origin "$BRANCH"

# 5. Tag + release. Default tag is v${VERSION}. Override with TAG=v1.2.3 if you
#    need an off-cycle tag.
HASH=$(git rev-parse --short HEAD)
HEAD_SHA=$(git rev-parse HEAD)
TAG="$EFFECTIVE_TAG"
SUBJECT=$(git log -1 --pretty=%s)

# Release notes: explicit second arg > NOTES_FILE > NOTES env > commit subject only.
NOTES_FROM_FILE=""
if [ -n "${NOTES_FILE:-}" ] && [ -f "${NOTES_FILE}" ]; then
    NOTES_FROM_FILE=$(cat "${NOTES_FILE}")
fi
NOTES="${NOTES_ARG:-${NOTES:-${NOTES_FROM_FILE:-$SUBJECT}}}"

# Pin --repo to the origin push URL so gh doesn't try to create the release
# on the upstream parent (which it prefers by default for forks).
ORIGIN_URL=$(git remote get-url origin)
REPO_SLUG=$(echo "$ORIGIN_URL" \
    | sed -E 's#^(https?://[^/]+/|git@[^:]+:)##' \
    | sed -E 's#\.git$##')
RELEASE_TITLE="Cyanide ${TAG}"

LOCAL_TAG_SHA=""
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    LOCAL_TAG_SHA=$(git rev-parse "refs/tags/$TAG^{commit}")
    if [ "$LOCAL_TAG_SHA" != "$HEAD_SHA" ]; then
        echo "error: local tag $TAG points to $LOCAL_TAG_SHA, not HEAD $HEAD_SHA" >&2
        exit 1
    fi
else
    echo "==> tagging $TAG"
    git tag "$TAG" "$HEAD_SHA"
fi

REMOTE_TAG_SHA=$(git ls-remote --tags origin "refs/tags/$TAG^{}" | awk '{print $1; exit}')
if [ -z "$REMOTE_TAG_SHA" ]; then
    REMOTE_TAG_SHA=$(git ls-remote --tags origin "refs/tags/$TAG" | awk '{print $1; exit}')
fi
if [ -n "$REMOTE_TAG_SHA" ] && [ "$REMOTE_TAG_SHA" != "$HEAD_SHA" ]; then
    echo "error: remote tag $TAG points to $REMOTE_TAG_SHA, not HEAD $HEAD_SHA" >&2
    exit 1
fi

if [ -z "$REMOTE_TAG_SHA" ]; then
    echo "==> pushing tag $TAG"
    git push origin "refs/tags/$TAG"
fi

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    echo "==> release $TAG already exists on $REPO_SLUG; replacing IPA asset"
    gh release upload "$TAG" "$IPA" --repo "$REPO_SLUG" --clobber
    gh release edit "$TAG" --repo "$REPO_SLUG" --title "$RELEASE_TITLE" --latest
else
    echo "==> creating release $TAG on $REPO_SLUG"
    gh release create "$TAG" "$IPA" \
        --repo "$REPO_SLUG" \
        --verify-tag \
        --latest \
        --title "$RELEASE_TITLE" \
        --notes "$NOTES"
fi

echo "==> done"
gh release view "$TAG" --repo "$REPO_SLUG" | head -10
