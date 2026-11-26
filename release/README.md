# Release tooling

Five scripts, each usable standalone (later ones build on earlier ones'
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

## `publish-git.sh`

Publishes a tagged hg release to the public git repository as a snapshot
(no hg history). It exports exactly the files of the hg tag `v<version>`
(`hg archive`, so ignored local files such as `.test-db*` and `keys/` are
never copied), mirrors them into the git working tree with
`rsync --delete` (files removed in hg disappear from git too), then
`git add -A`, commits and creates an annotated tag.

Pushing the `v<version>` tag (e.g. `v0.53`, `v0.5301`) makes CI build the tarball and
`.deb` and publish the GitHub release, so pushing is safe by default:

- without `--yes` it commits and tags in the local git tree only, and
  prints the push command (`git push --atomic`: branch and tag together).

It refuses a dirty git tree, an existing git tag, or a release with no
changes. All settings are variables at the top of the script and can be
overridden from the environment (`GIT_TREE`, default
`/tmp/github-out/perl-DBD-ClickhouseNG`; `GIT_REMOTE`, `GIT_PUSH_REF`,
`TAG`, `HG_REV`, `EXPORT_PARENT`, `RSYNC_EXCLUDES`, `COMMIT_MSG`, `TAG_MSG`).

The export goes to a private temporary directory under `EXPORT_PARENT`
(default `$TMPDIR`, else `/tmp`), removed when the script exits, also on
failure.

The hg repo exported is the one the script lives in (no setting), and
nothing is written into it. So the user owning the git tree can run it
directly from the hg owner's checkout, needing only read access there:

    ~hgowner/repo/release/publish-git.sh

hg may warn that it does not trust that repo's `.hg/hgrc`; that is harmless.

Typical release: `release/bump-version.pl NEW` (see below), write the
`Changes` entries, `hg commit`, `hg tag v<version>`, then:

    release/publish-git.sh          # commit + tag locally, inspect, then
                                    # run the printed push command
    release/publish-git.sh --yes    # or: all in one go, including the push

## `bump-version.pl`

Sets a new version in every place it is written by hand: `$VERSION` in
`lib/DBD/ClickhouseNG.pm`, `"version"` in `META.json` (edited in place,
formatting kept), and a new top `Changes` heading `NEW  YYYY-MM-DD` whose
entries you then write. Nothing is written unless all three edits apply.
`t/02-version.t` fails if the three ever disagree.

    release/bump-version.pl NEW [--amend]

Versions are plain decimals, and NEW must be higher than the current one
under Perl's version rules:

- a release with code changes: `0.53`, `0.54`, ...
- framework-only (CI/CD, packaging) re-releases of 0.53: `0.5301`,
  `0.5302`, ... (between 0.53 and 0.54)

Never use dotted forms like `0.53.01`: Perl/CPAN read them as v0.53.1 =
0.053001, which sorts *below* 0.51.

`--amend` renames the existing top `Changes` heading to NEW (and today's
date) instead of adding one, so a series of framework-only releases can
share a single `Changes` entry that you keep editing.
