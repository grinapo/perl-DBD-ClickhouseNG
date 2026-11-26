#!/usr/bin/env bash
# Publish a tagged hg release to the public git repository as a snapshot
# (no hg history): export exactly the files of the hg tag, mirror them into
# the git working tree, commit, create an annotated tag, and push branch and
# tag together. A pushed vNN.MM(.KK) tag makes CI build and publish the
# GitHub release.
#
# Pushing publishes to GitHub, so it's safe by default:
#   - without --yes it commits and tags in the local git tree only, then
#     prints the push command and exits 0.
#
# The hg repo exported is the one this script lives in, so another user
# (e.g. the one owning the git tree) can run it straight from there:
#   ~owner/repo/release/publish-git.sh
# That user only needs read access to the hg repo; nothing is written there.
#
# Every setting below can be overridden from the environment, e.g.
#   GIT_TREE=/srv/git/repo release/publish-git.sh
#
# Usage:
#   release/publish-git.sh [--yes]

set -euo pipefail

CONFIRMED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) CONFIRMED=1; shift ;;
        *) echo "release/publish-git.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"

GIT_TREE="${GIT_TREE:-/tmp/github-out/perl-DBD-ClickhouseNG}"  # checked-out public repo
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_PUSH_REF="${GIT_PUSH_REF:-HEAD}"         # branch to push with the tag (HEAD: current branch)
TAG="${TAG:-v$VERSION}"                      # git tag; also the hg tag exported, unless HG_REV is set
HG_REV="${HG_REV:-$TAG}"                     # hg revision to export
EXPORT_PARENT="${EXPORT_PARENT:-${TMPDIR:-/tmp}}"  # a private temp dir is created (and removed) here
RSYNC_EXCLUDES="${RSYNC_EXCLUDES:-.git .hgignore .hgtags}"  # never copied to, nor deleted from, GIT_TREE
COMMIT_MSG="${COMMIT_MSG:-Release $VERSION}"
TAG_MSG="${TAG_MSG:-Release $VERSION}"

command -v rsync >/dev/null 2>&1 || die "'rsync' not found -- install it first: sudo apt install rsync"
git -C "$GIT_TREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git working tree: $GIT_TREE"
[ -z "$( git -C "$GIT_TREE" status --porcelain )" ] \
    || die "git tree has uncommitted changes: $GIT_TREE"
! git -C "$GIT_TREE" rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || die "git tag $TAG already exists in $GIT_TREE"

TMP_DIR="$( mktemp -d "$EXPORT_PARENT/chng-git-export.XXXXXX" )"
trap 'rm -rf "$TMP_DIR"' EXIT
EXPORT_DIR="$TMP_DIR/export"

echo "release: exporting hg revision '$HG_REV' from $ROOT_DIR"
hg -R "$ROOT_DIR" archive -r "$HG_REV" "$EXPORT_DIR"
rm -f "$EXPORT_DIR/.hg_archival.txt"

echo "release: mirroring into $GIT_TREE"
excludes=()
for x in $RSYNC_EXCLUDES; do excludes+=( "--exclude=/$x" ); done
rsync -a --delete "${excludes[@]}" "$EXPORT_DIR/" "$GIT_TREE/"

git -C "$GIT_TREE" add -A
git -C "$GIT_TREE" diff --cached --quiet && die "nothing changed in $GIT_TREE -- already published?"
git -C "$GIT_TREE" status --short
git -C "$GIT_TREE" commit -q -m "$COMMIT_MSG"
git -C "$GIT_TREE" tag -a "$TAG" -m "$TAG_MSG"
echo "release: committed and tagged $TAG in $GIT_TREE"

PUSH=( git -C "$GIT_TREE" push --atomic "$GIT_REMOTE" "$GIT_PUSH_REF" "$TAG" )
if [ "$CONFIRMED" != 1 ]; then
    echo "release: not pushed. Check the commit, then push with:"
    echo "release:   ${PUSH[*]}"
    exit 0
fi

"${PUSH[@]}"
echo "release: pushed $TAG to $GIT_REMOTE"
