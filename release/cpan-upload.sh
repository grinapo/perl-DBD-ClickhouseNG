#!/usr/bin/env bash
# Upload the release tarball to PAUSE, publishing it to CPAN.
#
# This is a hard-to-reverse, public action, so it's safe by default:
#   - without --yes it only prints what it would do (dry run) and exits 0.
#   - credentials are never stored in this repo; pass them via the
#     PAUSE_USER / PAUSE_PASS environment variables.
#
# Requires (Debian package, not a manual CPAN install):
#   libcpan-uploader-perl (provides the 'cpan-upload' command)
#
# Usage:
#   PAUSE_USER=... PAUSE_PASS=... release/cpan-upload.sh [--allow-dirty] [--tarball PATH] [--yes]

set -euo pipefail

ALLOW_DIRTY=0
TARBALL_OVERRIDE=""
CONFIRMED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --tarball) TARBALL_OVERRIDE="$2"; shift 2 ;;
        --yes) CONFIRMED=1; shift ;;
        *) echo "release/cpan-upload.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"

command -v cpan-upload >/dev/null 2>&1 || die \
    "'cpan-upload' not found -- install it first: sudo apt install libcpan-uploader-perl"

TARBALL_TO_USE="${TARBALL_OVERRIDE:-$TARBALL}"
if [ -z "$TARBALL_OVERRIDE" ] && [ ! -f "$TARBALL_TO_USE" ]; then
    echo "release: no tarball at $TARBALL_TO_USE yet, building one"
    ALLOW_DIRTY=$ALLOW_DIRTY "$RELEASE_DIR/build-tarball.sh" $( [ "$ALLOW_DIRTY" = 1 ] && echo --allow-dirty )
fi
[ -f "$TARBALL_TO_USE" ] || die "tarball not found: $TARBALL_TO_USE"

: "${PAUSE_USER:?set PAUSE_USER to your PAUSE id}"
: "${PAUSE_PASS:?set PAUSE_PASS to your PAUSE password}"

if [ "$CONFIRMED" != 1 ]; then
    echo "release: DRY RUN -- would upload as PAUSE user '$PAUSE_USER':"
    echo "release:   $TARBALL_TO_USE"
    echo "release: re-run with --yes to actually upload (this publishes to CPAN and cannot be undone)"
    exit 0
fi

echo "release: uploading $TARBALL_TO_USE to PAUSE as '$PAUSE_USER'"
cpan-upload -u "$PAUSE_USER" -p "$PAUSE_PASS" "$TARBALL_TO_USE"
