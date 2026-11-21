# recon-gate-ci

[![recon-gate](https://github.com/kokan47ip-commits/recon-gate-ci/actions/workflows/recon-gate.yml/badge.svg?branch=main)](https://github.com/kokan47ip-commits/recon-gate-ci/actions/workflows/recon-gate.yml)

Self-contained reconciliation gate installer and PostgreSQL test harness.

## Local tests

Prerequisites: Node.js 22+, PostgreSQL 16 server and client tools, and a non-root shell (`initdb` refuses root).

```bash
bash tests/recon-installer.test.sh
```

```bash
PG_BINDIR="$(pg_config --bindir)" \
PSQL="$(command -v psql)" \
bash tests/recon-gate-postgres.test.sh
```

The PostgreSQL suite creates a temporary cluster and databases, exercises the pass and A0-skip paths, and checks every A1-A12 failure path. Set `RECON_KEEP=1` to retain its temporary directory.

## CI

The `recon-gate` workflow runs the installer, PostgreSQL, and archive-helper suites on Ubuntu 24.04 with PostgreSQL 16 and Node 22. A separate `archive-helper-bsdtar` job reruns the archive-helper suite on the pinned `macos-26` runner image, with BSD `libarchive` tar instead of GNU tar.

## Archive helper safety policy

`artifacts/find-and-archive-hajj-umrah.sh` refuses to build an archive rather than quietly changing what the project contains:

- **Symlinks** must be relative and stay inside the project. Absolute targets are refused even when they point inside the project, because such a link cannot work on the recipient's machine and still spells out this machine's layout. A dangling relative link is kept, since tar stores a link as a link.
- **Hard links** are refused for every file with more than one link, in-project links included: tar copies the shared bytes under whatever name the project gave it, so a copy of `~/.ssh/id_rsa` arriving as `src/app-state.json` is invisible to any name-based exclusion.

Files inside excluded output (`build/`, `dist/`, `.next/`, `coverage/`, and the rest) are exempt from both checks, because they never reach the archive. Both checks prune the same exclusion list the archive uses, so the checks and tar cannot drift apart.
