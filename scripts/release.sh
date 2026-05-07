#!/usr/bin/env bash
# Build, optionally commit + push, and publish the resulting IPA as a
# GitHub Release.
#
# Usage:
#   ./scripts/release.sh                                # use working-tree state, build + push (no commit)
#   ./scripts/release.sh "commit message"               # commit any changes, push, build, release
#   ./scripts/release.sh "commit message" "release notes"   # custom notes for the GH Release
#   NOTES_FILE=NOTES.md ./scripts/release.sh "..."      # read notes from a file
#   TAG=v1.2.3 ./scripts/release.sh "..."               # override tag (defaults to next vX.Y.Z tag)
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

# 1. Commit if there are changes and a message was provided.
DIRTY=0
if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    DIRTY=1
fi
if [ "$DIRTY" = "1" ]; then
    if [ -z "$MSG" ]; then
        echo "error: working tree has changes but no commit message was provided." >&2
        echo "       pass a message as the first arg, or stash changes." >&2
        exit 1
    fi
    echo "==> committing"
    git add -A
    git commit -m "$MSG"
fi

# 2. Push (no-op if already in sync).
echo "==> pushing $BRANCH"
git push origin "$BRANCH"

# 3. Build the IPA.
./scripts/build.sh
IPA="$PWD/build/kfun-zeroxjf.ipa"
if [ ! -f "$IPA" ]; then
    echo "error: $IPA not found after build" >&2
    exit 1
fi

next_release_tag() {
    latest=$(git ls-remote --tags origin 'refs/tags/v[0-9]*.[0-9]*.[0-9]*' \
        | awk '{print $2}' \
        | sed -E 's#refs/tags/##; s#\\^\\{\\}$##' \
        | awk -F. '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { printf "%d %d %d %s\n", substr($1, 2), $2, $3, $0 }' \
        | sort -k1,1n -k2,2n -k3,3n \
        | tail -1 \
        | awk '{print $4}')

    if [ -z "$latest" ]; then
        echo "v1.0.0"
        return
    fi

    version=${latest#v}
    major=${version%%.*}
    rest=${version#*.}
    minor=${rest%%.*}
    patch=${rest#*.}
    echo "v${major}.${minor}.$((patch + 1))"
}

# 4. Tag + release.
HASH=$(git rev-parse --short HEAD)
HEAD_SHA=$(git rev-parse HEAD)
TAG="${TAG:-$(next_release_tag)}"
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
RELEASE_TITLE="kfun-zeroxjf ${TAG}"

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
