#!/usr/bin/env bash
# Locate a local Node project for the Hajj/Umrah app and create a safe archive.
#
# Usage:
#   bash find-and-archive-hajj-umrah.sh
#   bash find-and-archive-hajj-umrah.sh --project /path/to/project
#   bash find-and-archive-hajj-umrah.sh --port 3000 --output /path/archive.tar.gz
#   bash find-and-archive-hajj-umrah.sh --exclude '*.log' --exclude=tmp
#
# The script searches common project folders first, then the process listening
# on the port, then the home directory. It refuses to guess when several
# projects match. Run it on the computer where localhost:3000 is running.

set -euo pipefail

PORT=3000
PROJECT=""
OUTPUT=""
RUNNING_PROJECT=""
candidates=()
excludes=()
listing=""
archive=""

usage() {
  cat <<'EOF'
Usage: find-and-archive-hajj-umrah.sh [options]

Options:
  --project PATH   Use this project directory instead of searching.
  --port PORT      Port to inspect with lsof (default: 3000).
  --output PATH    Archive path. Defaults to ~/hajj-umrah-app-<timestamp>.tar.gz.
  --exclude PATTERN  Add a tar exclusion (repeatable; equals form accepted).
  -h, --help       Show this help.

The archive excludes dependencies, build output, .git, and common secret files.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

cleanup() {
  if [ -n "$listing" ]; then
    rm -f "$listing"
  fi
}
trap cleanup EXIT

abort_archive() {
  [ -z "$archive" ] || rm -f "$archive"
  die "$@"
}

reject_forbidden() {
  local label="$1" pattern="$2" message="$3"
  if grep -Eq "$pattern" "$listing"; then
    printf '\nForbidden %s found:\n' "$label" >&2
    grep -E "$pattern" "$listing" | head -n 20 >&2 || true
    abort_archive "$message"
  fi
}

add_exclude() {
  [ -n "${1:-}" ] || die "--exclude requires a non-empty pattern"
  excludes+=("--exclude=$1")
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || die "--project requires a path"
      PROJECT=$2
      shift 2
      ;;
    --output)
      [ $# -ge 2 ] || die "--output requires a path"
      OUTPUT=$2
      shift 2
      ;;
    --port)
      [ $# -ge 2 ] || die "--port requires a number"
      PORT=$2
      shift 2
      ;;
    --exclude)
      [ $# -ge 2 ] || die "--exclude requires a pattern"
      add_exclude "$2"
      shift 2
      ;;
    --exclude=*)
      add_exclude "${1#--exclude=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$PORT" in
  '' | *[!0-9]*) die "--port must be a number" ;;
esac

[ -n "${HOME:-}" ] || die "HOME is not set"
for command_name in find grep tar mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

COMMON_ROOTS=(
  "$HOME/Projects"
  "$HOME/projects"
  "$HOME/Developer"
  "$HOME/Development"
  "$HOME/Code"
  "$HOME/code"
  "$HOME/Workspace"
  "$HOME/workspace"
  "$HOME/Workspaces"
  "$HOME/src"
  "$HOME/Documents"
  "$HOME/Desktop"
  "$HOME/Downloads"
  "$HOME/WebstormProjects"
)

# Candidates are deduplicated by device and inode, not by path: a
# case-insensitive filesystem (macOS APFS) makes "Projects" and "projects" the
# same directory, so the common-root scans would otherwise report one project
# twice and refuse to pick it as ambiguous.
candidate_keys=()

candidate_key() {
  local key
  key=$(stat -c '%d:%i' "$1" 2>/dev/null || true)
  [ -n "$key" ] || key=$(stat -f '%d:%i' "$1" 2>/dev/null || true)
  [ -n "$key" ] || key=$1
  printf '%s' "$key"
}

add_candidate() {
  local dir key existing
  [ -n "${1:-}" ] || return 0
  [ -d "$1" ] || return 0
  [ -f "$1/package.json" ] || return 0
  dir=$(cd "$1" 2>/dev/null && pwd -P) || return 0

  case "$dir" in
    "$HOME" | "/") return 0 ;;
    */node_modules/* | */.git/*) return 0 ;;
  esac

  key=$(candidate_key "$dir")
  if [ "${#candidate_keys[@]}" -gt 0 ]; then
    for existing in "${candidate_keys[@]}"; do
      [ "$existing" = "$key" ] && return 0
    done
  fi

  candidates+=("$dir")
  candidate_keys+=("$key")
  printf '    candidate: %s\n' "$dir"
}

package_matches() {
  grep -qiE 'hajj|umrah|travel' "$1" 2>/dev/null
}

scan_common_roots() {
  local root path dir
  for root in "${COMMON_ROOTS[@]}"; do
    [ -d "$root" ] || continue
    info "Checking common project folder: $root"

    while IFS= read -r -d '' path; do
      if [ -d "$path" ]; then
        add_candidate "$path"
      else
        dir=$(dirname "$path")
        if package_matches "$path"; then
          add_candidate "$dir"
        fi
      fi
    done < <(
      find "$root" -maxdepth 5 \
        \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
        \( -type d \( -iname '*hajj*' -o -iname '*umrah*' -o -iname '*travel*' \) -print0 \) -o \
        \( -type f -name package.json -print0 \) 2>/dev/null
    )
  done
}

find_running_project() {
  command -v lsof >/dev/null 2>&1 || return 0

  local pid dir
  pid=$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)
  [ -n "$pid" ] || return 0

  if [ -e "/proc/$pid/cwd" ]; then
    dir=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)
  else
    dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1 || true)
  fi
  [ -n "$dir" ] || return 0
  [ -f "$dir/package.json" ] || return 0

  RUNNING_PROJECT=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
  info "Port $PORT is served from: $RUNNING_PROJECT"
  add_candidate "$RUNNING_PROJECT"
}

find_home_projects() {
  local pkg dir
  info "Searching HOME for package.json mentioning hajj, umrah, or travel"
  while IFS= read -r -d '' pkg; do
    dir=$(dirname "$pkg")
    if package_matches "$pkg"; then
      add_candidate "$dir"
    fi
  done < <(
    find "$HOME" -maxdepth 6 \
      \( -path '*/Library' -o -path '*/node_modules' -o -path '*/.git' -o -path '*/AppData' \) -prune -o \
      -type f -name package.json -print0 2>/dev/null
  )

  info "Searching HOME for directories named hajj, umrah, or travel"
  while IFS= read -r -d '' dir; do
    add_candidate "$dir"
  done < <(
    find "$HOME" -maxdepth 5 \
      \( -path '*/Library' -o -path '*/node_modules' -o -path '*/.git' -o -path '*/AppData' \) -prune -o \
      -type d \( -iname '*hajj*' -o -iname '*umrah*' -o -iname '*travel*' \) -print0 2>/dev/null
  )
}

show_ambiguous() {
  printf '\nMultiple candidate projects were found:\n' >&2
  printf '  %s\n' "${candidates[@]}" >&2
  printf '\nRefusing to guess. Rerun with:\n  %s --project /path/to/project\n' "$0" >&2
  exit 2
}

if [ -n "$PROJECT" ]; then
  info "Using explicit project path: $PROJECT"
  add_candidate "$PROJECT"
  [ "${#candidates[@]}" -eq 1 ] || die "not a Node project (package.json missing): $PROJECT"
  project=${candidates[0]}
else
  scan_common_roots
  find_running_project

  if [ -n "$RUNNING_PROJECT" ]; then
    info "Using the project serving port $PORT"
    project=$RUNNING_PROJECT
  else
    info "No running project found on port $PORT; searching HOME before selecting"
    find_home_projects
    if [ "${#candidates[@]}" -eq 0 ]; then
      die "no project found. Rerun with --project /path/to/project"
    fi
    if [ "${#candidates[@]}" -gt 1 ]; then
      show_ambiguous
    fi
    info "Using the single project found"
    project=${candidates[0]}
  fi
fi

[ -f "$project/package.json" ] || die "package.json not found in $project"
[ "$project" != "$HOME" ] || die "refusing to archive the entire HOME directory"
[ "$project" != "/" ] || die "refusing to archive the filesystem root"

archive=${OUTPUT:-"$HOME/hajj-umrah-app-$(date +%Y%m%d-%H%M%S).tar.gz"}
mkdir -p "$(dirname "$archive")" || die "cannot create archive directory"
archive_dir=$(cd "$(dirname "$archive")" 2>/dev/null && pwd -P) || die "cannot resolve archive directory"
archive="$archive_dir/$(basename "$archive")"

case "$archive" in
  "$project"/*) die "archive must be outside the project: $archive" ;;
esac
if [ -e "$archive" ]; then
  die "archive already exists: $archive"
fi

info "Detected project: $project"
info "Creating archive: $archive"

excludes+=(
  "--exclude=.git"
  "--exclude=node_modules"
  "--exclude=.next"
  "--exclude=.nuxt"
  "--exclude=.svelte-kit"
  "--exclude=.output"
  "--exclude=.angular"
  "--exclude=.parcel-cache"
  "--exclude=.vite"
  "--exclude=.cache"
  "--exclude=.turbo"
  "--exclude=dist"
  "--exclude=build"
  "--exclude=out"
  "--exclude=coverage"
  "--exclude=.vercel"
  "--exclude=.wrangler"
  "--exclude=.env"
  "--exclude=.env.*"
  "--exclude=.envrc"
  "--exclude=.npmrc"
  "--exclude=.pypirc"
  "--exclude=.ssh"
  "--exclude=*.pem"
  "--exclude=*.key"
  "--exclude=*.p12"
  "--exclude=*.pfx"
  "--exclude=id_rsa"
  "--exclude=id_ed25519"
  "--exclude=.DS_Store"
)

umask 077
if ! tar -czf "$archive" "${excludes[@]}" -C "$project" .; then
  abort_archive "tar failed"
fi

listing=$(mktemp "${TMPDIR:-/tmp}/hajj-umrah-files.XXXXXX") || abort_archive "cannot create temporary file"

if ! tar -tzf "$archive" >"$listing"; then
  abort_archive "created archive could not be read"
fi

if ! grep -Eq '(^|/)package\.json$' "$listing"; then
  abort_archive "archive is missing package.json"
fi

forbidden_dirs='(^|/)(node_modules|\.next|\.nuxt|\.svelte-kit|\.output|\.angular|\.parcel-cache|\.vite|\.cache|dist|build|out|coverage|\.turbo|\.git|\.vercel|\.wrangler)(/|$)'
reject_forbidden "dependency/build paths" "$forbidden_dirs" "archive contains excluded dependency or build files"

forbidden_secrets='(^|/)(\.env($|/|\.)|\.envrc($|/)|\.ssh($|/)|\.npmrc$|\.pypirc$|id_rsa$|id_ed25519$)|\.(pem|key|p12|pfx)$'
reject_forbidden "secret files" "$forbidden_secrets" "archive contains excluded secret files"

count=$(wc -l <"$listing" | tr -d '[:space:]')
size=$(du -h "$archive")
size=${size%%[[:space:]]*}

printf '\nArchive ready.\n'
printf '  Project: %s\n' "$project"
printf '  Archive: %s\n' "$archive"
printf '  Files:   %s\n' "$count"
printf '  Size:    %s\n' "$size"
printf '\nVerified: no node_modules, build output, .git, or .env/secret files.\n'
printf 'Attach the archive to the chat.\n'
