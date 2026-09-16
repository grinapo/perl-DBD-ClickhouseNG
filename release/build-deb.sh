#!/usr/bin/env bash
# Build a local Debian binary package (.deb) from the release tarball, via
# dh-make-perl. This is for local install/testing, not for submission to
# the official Debian archive -- see "dh-make-perl(1)"'s own description of
# --build for that distinction.
#
# Requires (all in Debian's normal archive, not on CPAN):
#   dh-make-perl, debhelper, fakeroot
# Optional: lintian, to sanity-check the result.
#
# Usage: release/build-deb.sh [--allow-dirty] [--tarball PATH]
#
# Output: release/dist/<package>_<version>-1_all.deb

set -euo pipefail

ALLOW_DIRTY=0
TARBALL_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --tarball) TARBALL_OVERRIDE="$2"; shift 2 ;;
        *) echo "release/build-deb.sh: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=lib.sh
source "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/lib.sh"

for cmd in dh-make-perl fakeroot dpkg-checkbuilddeps; do
    command -v "$cmd" >/dev/null 2>&1 || die \
        "'$cmd' not found -- install it first: sudo apt install dh-make-perl fakeroot"
done

TARBALL_TO_USE="${TARBALL_OVERRIDE:-$TARBALL}"
if [ -z "$TARBALL_OVERRIDE" ] && [ ! -f "$TARBALL_TO_USE" ]; then
    echo "release: no tarball at $TARBALL_TO_USE yet, building one"
    ALLOW_DIRTY=$ALLOW_DIRTY "$RELEASE_DIR/build-tarball.sh" $( [ "$ALLOW_DIRTY" = 1 ] && echo --allow-dirty )
fi
[ -f "$TARBALL_TO_USE" ] || die "tarball not found: $TARBALL_TO_USE"

: "${DEBFULLNAME:=$( perl -MCPAN::Meta -e '
    my @authors = CPAN::Meta->load_file(shift)->author;
    my $a = $authors[0];
    print(($a =~ /\A(.*?)\s*<.*>\z/)[0] // $a);
' "$ROOT_DIR/META.json" )}"
: "${DEBEMAIL:=$( perl -MCPAN::Meta -e '
    my @authors = CPAN::Meta->load_file(shift)->author;
    my $a = $authors[0];
    print(($a =~ /<(.*)>/)[0] // "");
' "$ROOT_DIR/META.json" )}"

[ -n "$DEBFULLNAME" ] || die "could not determine maintainer name from META.json (set DEBFULLNAME yourself to override)"
[ -n "$DEBEMAIL" ] || die "could not determine maintainer email from META.json (set DEBEMAIL yourself to override)"
export DEBFULLNAME DEBEMAIL

DEB_WORK="$WORK_DIR/deb"
rm -rf "$DEB_WORK"
mkdir -p "$DEB_WORK"
tar -C "$DEB_WORK" -xzf "$TARBALL_TO_USE"

SRC_DIR="$DEB_WORK/$DIST_NAME"
[ -d "$SRC_DIR" ] || die "expected $SRC_DIR after extracting $TARBALL_TO_USE"

echo "release: running dh-make-perl (maintainer: $DEBFULLNAME <$DEBEMAIL>)"
dh-make-perl make "$SRC_DIR" --no-network --vcs none

# dh-make-perl's own templates default to "Artistic or GPL-1+" for the
# standard Perl dual license and don't pick up on our actual GPL-3-or-later
# text (from LICENSE / META.json's ["artistic_1","gpl_3"]), nor the real
# maintainer name for the debian/* copyright holder (it falls back to the
# system account's GECOS name, e.g. bare "grin" instead of "Peter Gervai").
# Fix both up in the generated debian/copyright before building.
echo "release: correcting debian/copyright (GPL-1+ -> GPL-3+, author name)"
YEAR="$( date +%Y )" DEBFULLNAME="$DEBFULLNAME" DEBEMAIL="$DEBEMAIL" perl -0777 -i -pe '
    s/^DISCLAIMER:.*?with this file\.\n//ms;
    s/^License: Artistic$/License: Artistic or GPL-3+/m;
    s/^License: Artistic or GPL-1\+$/License: Artistic or GPL-3+/m;
    s/^Copyright: (?:<INSERT COPYRIGHT YEAR\(S\) HERE>|\d+), .*$/Copyright: $ENV{YEAR}, $ENV{DEBFULLNAME} <$ENV{DEBEMAIL}>/mg;
    s{^License:[ ]GPL-1\+\n
        [ ]This[ ]program[ ]is[ ]free[ ]software;[ ]you[ ]can[ ]redistribute[ ]it[ ]and\/or[ ]modify\n
        [ ]it[ ]under[ ]the[ ]terms[ ]of[ ]the[ ]GNU[ ]General[ ]Public[ ]License[ ]as[ ]published[ ]by\n
        [ ]the[ ]Free[ ]Software[ ]Foundation;[ ]either[ ]version[ ]1,[ ]or[ ]\(at[ ]your[ ]option\)\n
        [ ]any[ ]later[ ]version\.\n
        [ ]\.\n
        [ ]On[ ]Debian[ ]systems,[ ]the[ ]complete[ ]text[ ]of[ ]version[ ]1[ ]of[ ]the[ ]GNU[ ]General\n
        [ ]Public[ ]License[ ]can[ ]be[ ]found[ ]in[ ]`\/usr\/share\/common-licenses\/GPL-1.\.\n
    }{License: GPL-3+\n This program is free software; you can redistribute it and\/or modify\n it under the terms of the GNU General Public License as published by\n the Free Software Foundation; either version 3, or (at your option)\n any later version.\n .\n On Debian systems, the complete text of version 3 of the GNU General\n Public License can be found in `\/usr\/share\/common-licenses\/GPL-3'"'"'.\n}mx;
' "$SRC_DIR/debian/copyright"

grep -q 'GPL-1' "$SRC_DIR/debian/copyright" && die \
    "debian/copyright still mentions GPL-1 after the fixup -- the substitution didn't match, check release/build-deb.sh"

dpkg-checkbuilddeps "$SRC_DIR/debian/control" || die \
    "missing build-dependencies -- install the packages dpkg-checkbuilddeps listed above, then re-run"

(
    cd "$SRC_DIR"
    fakeroot debian/rules binary
)

mkdir -p "$DIST_DIR"
find "$DEB_WORK" -maxdepth 1 -name '*.deb' -exec cp -v {} "$DIST_DIR/" \;

if command -v lintian >/dev/null 2>&1; then
    echo "release: lintian (informational -- dh-make-perl output isn't archive-ready as-is):"
    lintian "$DIST_DIR"/*.deb || true
fi
