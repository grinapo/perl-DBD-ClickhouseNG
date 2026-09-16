# Shared helpers for the release/*.sh scripts. Not meant to be run directly.

RELEASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$RELEASE_DIR/.." && pwd )"
DIST_DIR="$RELEASE_DIR/dist"
WORK_DIR="$RELEASE_DIR/work"

VERSION="$( perl -MExtUtils::MakeMaker -e '
    my $v = MM->parse_version(shift) // die "cannot find \$VERSION\n";
    print $v;
' "$ROOT_DIR/lib/DBD/ClickhouseNG.pm" )"
DIST_NAME="DBD-ClickhouseNG-$VERSION"
TARBALL="$DIST_DIR/$DIST_NAME.tar.gz"

die() { echo "release: $*" >&2; exit 1; }

require_clean_tree() {
    [ "${ALLOW_DIRTY:-0}" = 1 ] && return 0
    local status
    status="$( hg -R "$ROOT_DIR" status )"
    if [ -n "$status" ]; then
        echo "release: working tree is not clean:" >&2
        echo "$status" >&2
        die "commit or 'hg shelve' first, or re-run with --allow-dirty"
    fi
}

require_manifest_consistent() {
    ( cd "$ROOT_DIR" && perl -MExtUtils::Manifest=fullcheck -e '
        my ($missing, $extra) = fullcheck();
        if (@$missing || @$extra) {
            print STDERR "release: MANIFEST is out of sync with the working tree:\n";
            print STDERR "  missing (in MANIFEST, not on disk): $_\n" for @$missing;
            print STDERR "  extra (on disk, not in MANIFEST): $_\n" for @$extra;
            exit 1;
        }
    ' ) || die "fix MANIFEST/MANIFEST.SKIP before building a release"
}
