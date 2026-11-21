#!/usr/bin/env bash
# Tests for inspect-archive.sh.
#
# Uses the system tar, so running this on macOS exercises BSD tar.
# Run with: bash artifacts/test-inspect-archive.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
INSPECTOR="$SCRIPT_DIR/inspect-archive.sh"
[ -f "$INSPECTOR" ] || {
  printf 'error: inspector not found: %s\n' "$INSPECTOR" >&2
  exit 1
}

real_tar=$(command -v tar) || {
  printf 'error: tar is required\n' >&2
  exit 1
}
bash_bin=$(command -v bash) || {
  printf 'error: bash is required\n' >&2
  exit 1
}

# Resolve physically: macOS TMPDIR lives under /var, a symlink to /private/var.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/inspect-archive-tests.XXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT

total=0
failures=0
test_failures=0
test_name=""
output=""
status=0

start_test() {
  total=$((total + 1))
  test_name=$1
  test_failures=0
  printf '\ntest: %s\n' "$test_name"
}

end_test() {
  if [ "$test_failures" -eq 0 ]; then
    printf 'ok: %s\n' "$test_name"
  else
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$test_name" >&2
  fi
}

fail() {
  test_failures=$((test_failures + 1))
  printf '  - %s\n' "$*" >&2
}

run_inspector() {
  if output=$("$bash_bin" "$INSPECTOR" "$@" 2>&1); then
    status=0
  else
    status=$?
  fi
}

assert_status() {
  local expected=$1
  if [ "$status" -ne "$expected" ]; then
    fail "expected exit $expected, got $status"
    printf '%s\n' "$output" >&2
  fi
}

assert_output_contains() {
  case "$output" in
    *"$1"*) ;;
    *) fail "output is missing: $1" ;;
  esac
}

assert_output_lacks() {
  case "$output" in
    *"$1"*) fail "output should not contain: $1" ;;
  esac
}

# Build an archive the same way the helper does: from inside the project, so
# members are stored as ./, ./src/app.js and so on.
make_archive() {
  local dir=$1 archive=$2
  "$real_tar" -czf "$archive" -C "$dir" .
}

grow_dir() {
  mkdir -p "$1"
}

test_clean_archive_is_clean() {
  start_test "clean archive reports nothing flagged"
  local dir="$work/clean/project"
  local archive="$work/clean.tar.gz"
  grow_dir "$dir/src"
  printf '{"name":"clean"}\n' >"$dir/package.json"
  printf 'console.log("app");\n' >"$dir/src/app.js"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 0
  assert_output_contains "clean: nothing flagged"
  assert_output_contains "./src/app.js"
  assert_output_lacks "[absolute target]"
  end_test
}

test_secret_names_are_flagged() {
  start_test "secret files are flagged by name"
  local dir="$work/secrets/project"
  local archive="$work/secrets.tar.gz"
  grow_dir "$dir"
  printf 'name\n' >"$dir/package.json"
  printf 'SECRET=1\n' >"$dir/.env"
  printf 'key\n' >"$dir/id_rsa"
  printf 'key\n' >"$dir/local.pem"
  printf 'key\n' >"$dir/service-account.json"
  printf 'token\n' >"$dir/.npmrc"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./.env"
  assert_output_contains "./id_rsa"
  assert_output_contains "./local.pem"
  assert_output_contains "./service-account.json"
  assert_output_contains "./.npmrc"
  end_test
}

test_build_output_is_flagged() {
  start_test "dependency and build output are flagged"
  local dir="$work/build/project"
  local archive="$work/build.tar.gz"
  grow_dir "$dir/node_modules/pkg"
  grow_dir "$dir/build"
  grow_dir "$dir/.next/server"
  printf 'name\n' >"$dir/package.json"
  printf 'dep\n' >"$dir/node_modules/pkg/index.js"
  printf 'built\n' >"$dir/build/out.js"
  printf 'built\n' >"$dir/.next/server/page.js"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./node_modules/"
  assert_output_contains "./build/"
  assert_output_contains "./.next/"
  end_test
}

test_data_dumps_and_nested_archives_are_flagged() {
  start_test "data dumps, logs and nested archives are flagged"
  local dir="$work/data/project"
  local archive="$work/data.tar.gz"
  grow_dir "$dir"
  printf 'name\n' >"$dir/package.json"
  printf 'x\n' >"$dir/app.sqlite"
  printf 'x\n' >"$dir/dump.sql"
  printf 'x\n' >"$dir/run.log"
  printf 'x\n' >"$dir/backup.zip"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./app.sqlite"
  assert_output_contains "./dump.sql"
  assert_output_contains "./run.log"
  assert_output_contains "./backup.zip"
  end_test
}

test_absolute_symlink_is_flagged() {
  start_test "symlink with an absolute target is flagged"
  local dir="$work/absolute/project"
  local archive="$work/absolute.tar.gz"
  grow_dir "$dir"
  printf 'name\n' >"$dir/package.json"
  ln -s /etc/passwd "$dir/leak"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./leak -> /etc/passwd [absolute target]"
  end_test
}

test_escaping_symlink_is_flagged() {
  start_test "relative symlink that leaves the archive is flagged"
  local dir="$work/escape/project"
  local archive="$work/escape.tar.gz"
  grow_dir "$dir/src"
  printf 'name\n' >"$dir/package.json"
  ln -s ../../outside.txt "$dir/src/up"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./src/up -> ../../outside.txt [leaves the archive]"
  end_test
}

test_in_project_symlink_is_not_flagged() {
  start_test "in-project relative symlink is reported but not flagged"
  local dir="$work/inside/project"
  local archive="$work/inside.tar.gz"
  grow_dir "$dir/src"
  printf 'name\n' >"$dir/package.json"
  printf 'app\n' >"$dir/src/app.js"
  ln -s app.js "$dir/src/link"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 0
  assert_output_contains "./src/link -> app.js"
  assert_output_lacks "[leaves the archive]"
  end_test
}

test_hard_link_entries_are_reported() {
  start_test "hard-link entries are reported"
  local dir="$work/hardlink/project"
  local archive="$work/hardlink.tar.gz"
  grow_dir "$dir"
  printf 'name\n' >"$dir/package.json"
  printf 'shared\n' >"$dir/original.txt"
  ln "$dir/original.txt" "$dir/second-name.txt"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "hard-link entries"
  assert_output_contains "link to"
  end_test
}

test_key_material_in_an_ordinary_file_is_flagged() {
  start_test "key material in an ordinary file is flagged in full mode"
  local dir="$work/content/project"
  local archive="$work/content.tar.gz"
  grow_dir "$dir/src"
  printf 'name\n' >"$dir/package.json"
  printf 'const k = "-----BEGIN RSA PRIVATE KEY-----";\n' >"$dir/src/config.js"
  make_archive "$dir" "$archive"

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "./src/config.js"
  assert_output_contains "PRIVATE KEY"
  end_test
}

test_preview_skips_the_content_scan() {
  start_test "--preview does not read file contents"
  local dir="$work/preview/project"
  local archive="$work/preview.tar.gz"
  grow_dir "$dir/src"
  printf 'name\n' >"$dir/package.json"
  printf 'const k = "-----BEGIN RSA PRIVATE KEY-----";\n' >"$dir/src/config.js"
  make_archive "$dir" "$archive"

  run_inspector --preview "$archive"
  assert_status 0
  assert_output_contains "./src/config.js"
  assert_output_contains "(skipped: --preview does not read file contents)"
  assert_output_lacks "PRIVATE KEY"
  end_test
}

test_unsafe_member_paths_are_flagged() {
  start_test "absolute and parent-directory member names are flagged"
  local dir="$work/unsafe/project"
  local archive="$work/unsafe.tar.gz"
  grow_dir "$dir"
  printf 'x\n' >"$dir/evil.txt"

  if "$real_tar" --version 2>/dev/null | grep -q GNU; then
    # Only GNU tar can write such a member; BSD tar refuses to create it.
    "$real_tar" -czf "$archive" --transform 's|^evil.txt$|../evil.txt|' -C "$dir" evil.txt
  else
    (cd "$dir" && "$real_tar" -czf "$archive" --format=ustar evil.txt)
    printf 'no-parent-member\n' >"$dir/skip"
  fi

  if ! "$real_tar" -tzf "$archive" 2>/dev/null | grep -q '\.\./evil\.txt'; then
    printf 'skip: this tar cannot build a ".." member\n'
    total=$((total - 1))
    return 0
  fi

  run_inspector "$archive"
  assert_status 1
  assert_output_contains "../evil.txt"
  assert_output_contains "unsafe member paths"
  assert_output_contains "(not run: the archive has unsafe member paths)"
  end_test
}

test_unreadable_archive_exits_two() {
  start_test "unreadable archive exits 2"
  local file="$work/broken.tar.gz"
  printf 'not an archive\n' >"$file"

  run_inspector "$file"
  assert_status 2
  assert_output_contains "cannot read archive"
  end_test
}

test_usage_errors_exit_two() {
  start_test "usage errors exit 2"
  run_inspector
  assert_status 2
  assert_output_contains "usage: inspect-archive.sh"

  run_inspector --nonsense
  assert_status 2
  assert_output_contains "unknown argument"
  end_test
}

test_clean_archive_is_clean
test_secret_names_are_flagged
test_build_output_is_flagged
test_data_dumps_and_nested_archives_are_flagged
test_absolute_symlink_is_flagged
test_escaping_symlink_is_flagged
test_in_project_symlink_is_not_flagged
test_hard_link_entries_are_reported
test_key_material_in_an_ordinary_file_is_flagged
test_preview_skips_the_content_scan
test_unsafe_member_paths_are_flagged
test_unreadable_archive_exits_two
test_usage_errors_exit_two

if [ "$failures" -ne 0 ]; then
  printf '\n%d of %d tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d tests passed.\n' "$total"
