#!/usr/bin/env bash
# Inspect an app archive before it is reviewed or shared: every member name, the
# names that look like they could carry a secret, the link entries, unsafe member
# paths, and (unless --preview) a scan of the contents for key material.
#
# Usage:
#   bash inspect-archive.sh ARCHIVE
#   bash inspect-archive.sh --preview ARCHIVE
#
# --preview prints the names, the name flags and the link entries, and skips the
# content scan. It is what a sender needs before uploading an archive; the
# receiving side runs without it.
#
# Exit status:
#   0  nothing flagged
#   1  something flagged; read the report
#   2  usage error, or the archive could not be read
#
# The NAME_FLAGS and CONTENT_FLAGS lists below are the single source of truth for
# what counts as suspicious. Anything that previews an archive should call this
# script instead of copying the patterns.

set -euo pipefail

# Names that should never ship: secret files, key material, credential stores,
# data dumps, nested archives, and the build/dependency trees the helper excludes.
NAME_FLAGS='(^|/)\.env($|\.|/)|(^|/)\.envrc$|(^|/)\.ssh(/|$)|(^|/)\.npmrc$|(^|/)\.pypirc$|(^|/)\.netrc$|(^|/)\.git-credentials$|(^|/)\.aws(/|$)|(^|/)\.kube(/|$)|(^|/)\.docker/config\.json$|(^|/)\.config/gcloud(/|$)|(^|/)\.vercel(/|$)|(^|/)\.wrangler(/|$)|(^|/)id_(rsa|dsa|ecdsa|ed25519)|(^|/)AuthKey_[A-Za-z0-9]+\.p8$|service[-_]?account[^/]*\.json$|firebase-adminsdk[^/]*\.json$|\.(pem|key|p12|pfx|p8|jks|keystore|mobileprovision|ovpn)$|(^|/)(credentials|secrets?|passwords?|tokens?)(\.|$)|(^|/)[^/]*secret[^/]*$|(^|/)config\.json$|(^|/)\.git(/|$)|(^|/)node_modules(/|$)|(^|/)(build|dist|out|coverage|\.next)(/|$)|\.(sqlite3?|db|dump|sql|bak|log)$|\.(zip|tar|tgz|gz|7z)$|(^|/)\.DS_Store$'

# Content that should never ship even when the file name looks harmless.
CONTENT_FLAGS='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk_(live|test)_[A-Za-z0-9]{10,}|rk_(live|test)_[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|postgres(ql)?://[^:@/[:space:]]+:[^@/[:space:]]+@|mysql://[^:@/[:space:]]+:[^@/[:space:]]+@|mongodb([+]srv)?://[^:@/[:space:]]+:[^@/[:space:]]+@'

# Assignments with a long literal value. Noisier than CONTENT_FLAGS on purpose:
# these are for a human to look at, not for a verdict.
GENERIC_FLAGS="(api[_-]?key|apikey|secret|password|passwd|passphrase|token|client[_-]?secret)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9/+_.-]{16,}"

MAX_FILE_BYTES=10485760
MAX_PER_FILE=5
MAX_CONTENT_LINES=40

usage() {
  cat <<'EOF'
Usage: inspect-archive.sh [--preview] ARCHIVE

  --preview   Print the names, the name flags and the link entries only.
              Skips the content scan.
  -h, --help  Show this help.

Exit status: 0 nothing flagged, 1 something flagged, 2 usage error or unreadable
archive.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

section() {
  printf '\n-- %s --\n' "$1"
}

mode=full
archive=""
while [ $# -gt 0 ]; do
  case "$1" in
    --preview)
      mode=preview
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      [ -z "$archive" ] || die "expected one archive, got: $1"
      archive=$1
      shift
      ;;
  esac
done

[ -n "$archive" ] || die "usage: inspect-archive.sh [--preview] ARCHIVE"
[ -f "$archive" ] || die "not a file: $archive"

work=$(mktemp -d "${TMPDIR:-/tmp}/inspect-archive.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf "$work"' EXIT

names="$work/names.txt"
entries="$work/entries.txt"
if ! tar -tzf "$archive" >"$names" 2>"$work/tar.err"; then
  die "cannot read archive: $archive ($(head -n 1 "$work/tar.err" 2>/dev/null || true))"
fi
tar -tvzf "$archive" >"$entries" 2>/dev/null || true

total=$(wc -l <"$names" | tr -d '[:space:]')
flags=0
content_lines=0

printf '== archive: %s\n' "$archive"
printf '== entries: %s\n' "$total"
printf '== mode: %s\n' "$mode"

if [ "$total" -eq 0 ]; then
  printf '\n-- summary --\n  archive has no entries\n'
  exit 1
fi

section "file names"
sed 's/^/  /' "$names"

section "flagged names"
if grep -Ei "$NAME_FLAGS" "$names" >"$work/flagged.txt"; then
  sed 's/^/  /' "$work/flagged.txt"
  flagged=$(wc -l <"$work/flagged.txt" | tr -d '[:space:]')
  flags=$((flags + flagged))
else
  printf '  (none)\n'
fi

# A hard link is the same inode as its other name, so tar copies the shared bytes
# under whatever name the project used: never something to review line by line.
section "hard-link entries"
if grep -E '^h|link to' "$entries" >"$work/hardlinks.txt"; then
  sed 's/^/  /' "$work/hardlinks.txt"
  hardlinked=$(wc -l <"$work/hardlinks.txt" | tr -d '[:space:]')
  flags=$((flags + hardlinked))
else
  printf '  (none)\n'
fi

# Member names are validated before anything is extracted: an absolute path or a
# ".." component is a finding by itself, and nothing is written for such an
# archive.
awk '{ bad = ($0 ~ /^\//); n = split($0, a, "/"); for (i = 1; i <= n; i++) if (a[i] == "..") bad = 1; if (bad) print }' \
  "$names" >"$work/unsafe.txt" || true

section "unsafe member paths"
if [ -s "$work/unsafe.txt" ]; then
  sed 's/^/  /' "$work/unsafe.txt"
  unsafe=$(wc -l <"$work/unsafe.txt" | tr -d '[:space:]')
  flags=$((flags + unsafe))
else
  printf '  (none)\n'
fi

# True when a relative target leaves the archive, counted from the link's own
# directory. Mirrors the helper's lexical check: nothing is resolved on disk.
escapes_archive() {
  awk -v base="$1" -v target="$2" 'BEGIN{
    depth = 0
    n = split(base, a, "/")
    for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != ".") depth++
    n = split(target, b, "/")
    for (i = 1; i <= n; i++) {
      if (b[i] == "" || b[i] == ".") continue
      if (b[i] == "..") { depth--; if (depth < 0) { print "yes"; exit } }
      else depth++
    }
    print "no"
  }'
}

if [ -s "$work/unsafe.txt" ]; then
  section "link entries"
  printf '  (not read: the archive has unsafe member paths)\n'
  section "content scan"
  printf '  (not run: the archive has unsafe member paths)\n'
  printf '\n-- summary --\n  %s flagged item(s); do not extract this archive outside a sandbox\n' "$flags"
  exit 1
fi

tree="$work/tree"
mkdir -p "$tree"
if ! tar -xzf "$archive" -C "$tree" 2>"$work/extract.err"; then
  die "cannot extract archive for inspection: $archive ($(head -n 1 "$work/extract.err" 2>/dev/null || true))"
fi

section "link entries"
links=0
while IFS= read -r -d '' link; do
  rel=${link#"$tree"/}
  target=$(readlink "$link") || continue
  case "$target" in
    /*)
      printf '  ./%s -> %s [absolute target]\n' "$rel" "$target"
      flags=$((flags + 1))
      ;;
    *)
      if [ "$(escapes_archive "$(dirname "$rel")" "$target")" = yes ]; then
        printf '  ./%s -> %s [leaves the archive]\n' "$rel" "$target"
        flags=$((flags + 1))
      else
        printf '  ./%s -> %s\n' "$rel" "$target"
      fi
      ;;
  esac
  links=$((links + 1))
done < <(find "$tree" -type l -print0 2>/dev/null)
[ "$links" -gt 0 ] || printf '  (none)\n'

section "content scan"
if [ "$mode" = preview ]; then
  printf '  (skipped: --preview does not read file contents)\n'
else
  scanned=0
  truncated=0
  while IFS= read -r -d '' file; do
    rel=${file#"$tree"/}
    size=$(wc -c <"$file" | tr -d '[:space:]')
    if [ "${size:-0}" -gt "$MAX_FILE_BYTES" ]; then
      printf '  %s: skipped, larger than 10 MB\n' "$rel"
      continue
    fi
    scanned=$((scanned + 1))

    if [ "$content_lines" -ge "$MAX_CONTENT_LINES" ]; then
      truncated=1
      break
    fi

    # -e, because a key pattern starts with "-----" and would read as options.
    hits=$(grep -aInE -e "$CONTENT_FLAGS|$GENERIC_FLAGS" "$file" 2>/dev/null | head -n "$MAX_PER_FILE" | cut -c1-200 || true)
    [ -n "$hits" ] || continue

    while IFS= read -r line; do
      printf '  %s:%s\n' "$rel" "$line"
    done <<<"$hits"
    found=$(printf '%s\n' "$hits" | wc -l | tr -d '[:space:]')
    flags=$((flags + found))
    content_lines=$((content_lines + found))
  done < <(find "$tree" -type f -print0 2>/dev/null)

  if [ "$content_lines" -eq 0 ]; then
    printf '  (no matches in %s files)\n' "$scanned"
  elif [ "$truncated" -eq 1 ]; then
    printf '  (stopped after %s matches)\n' "$content_lines"
  fi
fi

section "summary"
if [ "$flags" -eq 0 ]; then
  printf '  clean: nothing flagged\n'
  exit 0
fi
printf '  %s flagged item(s); review the sections above\n' "$flags"
exit 1
