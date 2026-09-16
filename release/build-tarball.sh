#!/usr/bin/env bash
# Build the CPAN release tarball from exactly the files listed in MANIFEST,
# and verify it by running Build.PL/Build/Build test against a scratch copy
# assembled from that same file list (catches a MANIFEST that's silently
# missing a file the working tree has).
#
# Usage: release/build-tarball.sh [--allow-dirty]
#
# Output: release/dist/DBD-ClickhouseNG-<version>.tar.gz

set -euo pipefail

ALLOW_DIRTY=0
for arg in "$@"; do
    case "$arg" in
        --allow-dirty) ALLOW_DIRTY=1 ;;
        *) echo "release/build-tarball.sh: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"

require_clean_tree
require_manifest_consistent

echo "release: building $DIST_NAME"

rm -rf "$WORK_DIR/$DIST_NAME"
mkdir -p "$WORK_DIR/$DIST_NAME" "$DIST_DIR"

while IFS= read -r f; do
    [ -z "$f" ] && continue
    mkdir -p "$WORK_DIR/$DIST_NAME/$( dirname "$f" )"
    cp "$ROOT_DIR/$f" "$WORK_DIR/$DIST_NAME/$f"
done < "$ROOT_DIR/MANIFEST"

echo "release: verifying the assembled tree builds and tests clean"
(
    cd "$WORK_DIR/$DIST_NAME"
    perl Build.PL >/dev/null
    ./Build >/dev/null
    ./Build test
    rm -rf blib Build _build_params MYMETA.json MYMETA.yml
)

tar --numeric-owner --owner=0 --group=0 -C "$WORK_DIR" -czf "$TARBALL" "$DIST_NAME"

echo "release: wrote $TARBALL"
