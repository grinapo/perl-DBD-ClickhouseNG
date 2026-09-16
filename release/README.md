# Release tooling

Three scripts, each usable standalone (later ones build on earlier ones'
output automatically if it's missing). Run from anywhere; they locate the
repo root themselves. All output goes to `release/dist/` (hgignored --
regenerate, don't commit).

## `build-tarball.sh`

Builds `release/dist/DBD-ClickhouseNG-<version>.tar.gz` from exactly the
files listed in `MANIFEST` (the same list PAUSE/CPAN tooling will use), and
verifies it by running `Build.PL`/`Build`/`Build test` against a scratch
copy assembled from that file list -- catches a `MANIFEST` that's silently
missing a file the working tree has.

Refuses to run against an uncommitted (`hg status` non-empty) tree unless
you pass `--allow-dirty`.

    release/build-tarball.sh [--allow-dirty]

## `build-deb.sh`

Builds a local Debian binary package (`.deb`) from the release tarball via
`dh-make-perl`, for local install/testing -- not for submission to the
official Debian archive (`dh-make-perl`'s own docs make that distinction;
the generated `debian/copyright` etc. need manual cleanup for that).
Builds the tarball first if one doesn't already exist.

`dh-make-perl`'s own templates default to "Artistic or GPL-1+" for the
generic Perl dual license, regardless of what the module's actual license
text says, and pick up the system account's GECOS name rather than the
real maintainer name for the `debian/*` copyright holder. The script
patches the generated `debian/copyright` afterwards to say GPL-3-or-later
(matching `LICENSE`/`META.json`) and the correct name/email from
`META.json`, before building.

Requires (Debian packages, all in the normal archive):

    sudo apt install dh-make-perl fakeroot

    release/build-deb.sh [--allow-dirty] [--tarball PATH]

## `cpan-upload.sh`

Uploads the release tarball to PAUSE, publishing it to CPAN. Builds the
tarball first if one doesn't already exist.

This is a hard-to-reverse, public action, so it's safe by default:

- without `--yes` it only prints what it would do and exits -- nothing is
  uploaded.
- credentials are never stored in this repo; pass them via the
  `PAUSE_USER` / `PAUSE_PASS` environment variables.

Requires:

    sudo apt install libcpan-uploader-perl

Usage:

    PAUSE_USER=... PAUSE_PASS=... release/cpan-upload.sh [--allow-dirty] [--tarball PATH] [--yes]
