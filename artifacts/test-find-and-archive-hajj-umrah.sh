#!/usr/bin/env bash
# Functional tests for find-and-archive-hajj-umrah.sh.
#
# Uses the system tar, so running this on macOS exercises BSD tar.
# Run with: bash artifacts/test-find-and-archive-hajj-umrah.sh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
HELPER="$SCRIPT_DIR/find-and-archive-hajj-umrah.sh"
[ -f "$HELPER" ] || {
  printf 'error: helper not found: %s\n' "$HELPER" >&2
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

ORIGINAL_PATH=${PATH:-}
UNUSED_PORT=39876
# Resolve to a physical path: macOS TMPDIR lives under /var, a symlink to
# /private/var, and the helper reports projects with `pwd -P`.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hajj-umrah-tests.XXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT

total=0
failures=0
test_failures=0
test_name=""
output=""
status=0
test_path=$ORIGINAL_PATH

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

run_helper() {
  local home=$1
  shift
  if output=$(HOME="$home" PATH="$test_path" "$bash_bin" "$HELPER" "$@" 2>&1); then
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

assert_file_exists() {
  if [ ! -f "$1" ]; then
    fail "expected file is missing: $1"
  fi
}

assert_file_absent() {
  if [ -e "$1" ]; then
    fail "unexpected file exists: $1"
  fi
}

assert_archive_has() {
  local file=$1 pattern=$2
  if [ ! -f "$file" ]; then
    fail "archive is missing: $file"
    return 0
  fi
  if ! "$real_tar" -tzf "$file" | grep -Eq "$pattern" >/dev/null; then
    fail "archive is missing pattern: $pattern"
  fi
}

assert_archive_lacks() {
  local file=$1 pattern=$2
  if [ ! -f "$file" ]; then
    fail "archive is missing: $file"
    return 0
  fi
  if "$real_tar" -tzf "$file" | grep -Eq "$pattern" >/dev/null; then
    fail "archive contains forbidden pattern: $pattern"
  fi
}

assert_archive_has_no_escaping_links() {
  local file=$1 targets target
  if [ ! -f "$file" ]; then
    fail "archive is missing: $file"
    return 0
  fi
  targets=$("$real_tar" -tzvf "$file" | awk '$1 ~ /^l/ && / -> / { sub(/^.* -> /, ""); print }')
  [ -n "$targets" ] || return 0
  while IFS= read -r target; do
    case "$target" in
      /* | .. | ../* | */../* | */..) fail "archive links outside the project: $target" ;;
    esac
  done < <(printf '%s\n' "$targets")
}

make_project() {
  local dir=$1 name=$2
  mkdir -p "$dir/src"
  printf '{"name":"%s","private":true}\n' "$name" >"$dir/package.json"
  printf 'console.log("app");\n' >"$dir/src/app.js"
}

make_unsafe_files() {
  local project=$1 dir
  for dir in node_modules .next .nuxt .svelte-kit .output .angular .parcel-cache .vite .cache .turbo dist build out coverage .git .vercel .wrangler .ssh; do
    mkdir -p "$project/$dir"
    printf 'generated\n' >"$project/$dir/leak.txt"
  done

  printf 'SECRET=1\n' >"$project/.env"
  printf 'SECRET=1\n' >"$project/.env.local"
  printf 'SECRET=1\n' >"$project/.envrc"
  printf 'SECRET=1\n' >"$project/.npmrc"
  printf 'SECRET=1\n' >"$project/.pypirc"
  printf 'key\n' >"$project/local.pem"
  printf 'key\n' >"$project/local.key"
  printf 'key\n' >"$project/local.p12"
  printf 'key\n' >"$project/local.pfx"
  printf 'key\n' >"$project/id_rsa"
  printf 'key\n' >"$project/id_ed25519"
  printf 'metadata\n' >"$project/.DS_Store"
}

test_common_detection_and_exclusions() {
  start_test "common-folder detection and safe archive"
  local home="$work/common/home"
  local project="$home/Projects/HajjUmrahApp"
  local found="" candidate
  make_project "$project" "hajj-umrah-app"
  make_unsafe_files "$project"

  run_helper "$home" --port "$UNUSED_PORT"
  assert_status 0
  assert_output_contains "Detected project: $project"
  assert_output_contains "Verified: no node_modules"

  for candidate in "$home"/hajj-umrah-app-*.tar.gz; do
    if [ -f "$candidate" ]; then
      found=$candidate
      break
    fi
  done
  assert_file_exists "$found"
  assert_archive_has "$found" '(^|/)package\.json$'
  assert_archive_has "$found" '(^|/)src/app\.js$'
  assert_archive_lacks "$found" '(^|/)(node_modules|\.next|\.nuxt|\.svelte-kit|\.output|\.angular|\.parcel-cache|\.vite|\.cache|dist|build|out|coverage|\.turbo|\.git|\.vercel|\.wrangler)(/|$)'
  assert_archive_lacks "$found" '(^|/)(\.env($|/|\.)|\.envrc($|/)|\.ssh($|/)|\.npmrc$|\.pypirc$|id_rsa$|id_ed25519$)|\.(pem|key|p12|pfx)$'
  end_test
}

test_repeatable_exclude_option() {
  start_test "repeatable --exclude option (both forms)"
  local home="$work/custom-exclude/home"
  local project="$home/Projects/HajjUmrahApp"
  local archive="$work/custom-exclude.tar.gz"
  make_project "$project" "hajj-umrah-app"
  printf 'keep\n' >"$project/keep.txt"
  printf 'drop one\n' >"$project/drop-one.txt"
  printf 'drop two\n' >"$project/drop-two.txt"

  run_helper "$home" --port "$UNUSED_PORT" --output "$archive" \
    --exclude drop-one.txt --exclude=drop-two.txt
  assert_status 0
  assert_archive_has "$archive" '(^|/)keep\.txt$'
  assert_archive_lacks "$archive" '(^|/)drop-one\.txt$'
  assert_archive_lacks "$archive" '(^|/)drop-two\.txt$'
  end_test
}

test_home_search_ambiguity() {
  start_test "home search detects a second candidate"
  local home="$work/ambiguity/home"
  local common="$home/Projects/TravelApp"
  local other="$home/elsewhere/UmrahPlanner"
  make_project "$common" "travel-app"
  make_project "$other" "umrah-planner"

  run_helper "$home" --port "$UNUSED_PORT" --output "$home/should-not-exist.tar.gz"
  assert_status 2
  assert_output_contains "Multiple candidate projects were found"
  assert_output_contains "$common"
  assert_output_contains "$other"
  assert_file_absent "$home/should-not-exist.tar.gz"
  end_test
}

test_explicit_project_override() {
  start_test "explicit --project override"
  local home="$work/explicit/home"
  local chosen="$home/Projects/ChosenApp"
  local other="$home/Other/TravelApp"
  local archive="$work/explicit.tar.gz"
  make_project "$chosen" "chosen-app"
  printf 'chosen\n' >"$chosen/src/chosen.txt"
  make_project "$other" "travel-app"
  printf 'other\n' >"$other/src/other.txt"

  run_helper "$home" --project "$chosen" --output "$archive" --port "$UNUSED_PORT"
  assert_status 0
  assert_output_contains "Using explicit project path: $chosen"
  assert_archive_has "$archive" '(^|/)src/chosen\.txt$'
  assert_archive_lacks "$archive" '(^|/)src/other\.txt$'
  end_test
}

test_no_project_found() {
  start_test "no project found fails clearly"
  local home="$work/empty/home"
  mkdir -p "$home"

  run_helper "$home" --port "$UNUSED_PORT"
  assert_status 1
  assert_output_contains "no project found"
  end_test
}

test_ssh_leak_is_rejected() {
  start_test "forced .ssh leak is rejected"
  local home="$work/leak/home"
  local project="$home/Projects/HajjUmrahApp"
  local bin="$work/leak/bin"
  local archive="$home/leak.tar.gz"
  make_project "$project" "hajj-umrah-app"
  mkdir -p "$project/.ssh"
  printf 'ssh\n' >"$project/.ssh/config"

  mkdir -p "$bin"
  cat >"$bin/tar" <<EOF
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
  if [ "\$arg" = "--exclude=.ssh" ]; then
    continue
  fi
  args+=("\$arg")
done
exec "$real_tar" "\${args[@]}"
EOF
  chmod +x "$bin/tar"

  test_path="$bin:$ORIGINAL_PATH"
  run_helper "$home" --port "$UNUSED_PORT" --output "$archive"
  test_path=$ORIGINAL_PATH

  assert_status 1
  assert_output_contains "Forbidden secret files found"
  assert_file_absent "$archive"
  end_test
}

test_symlink_outside_project_is_not_archived() {
  start_test "symlink pointing at ~/.ssh is not archived"
  local home="$work/symlink/home"
  local project="$home/Projects/HajjUmrahApp"
  local ssh_dir="$home/.ssh"
  local archive="$work/symlink.tar.gz"
  make_project "$project" "hajj-umrah-app"
  printf 'keep\n' >"$project/keep.txt"

  mkdir -p "$ssh_dir/nested"
  printf 'Host *\n' >"$ssh_dir/config"
  printf 'PRIVATE KEY\n' >"$ssh_dir/id_rsa"
  printf 'ssh-rsa AAAA\n' >"$ssh_dir/authorized_keys"
  printf 'deep secret\n' >"$ssh_dir/nested/deep.txt"

  ln -s "$ssh_dir" "$project/ssh-link"
  ln -s "$ssh_dir/id_rsa" "$project/key-link"
  ln -s src "$project/src-link"

  run_helper "$home" --project "$project" --output "$archive" --port "$UNUSED_PORT"
  assert_status 0
  assert_output_contains "Dropping symlink(s) that point outside the project"
  assert_output_contains "ssh-link"
  assert_archive_has "$archive" '(^|/)package\.json$'
  assert_archive_has "$archive" '(^|/)keep\.txt$'
  assert_archive_has "$archive" '(^|/)src-link$'
  assert_archive_lacks "$archive" '(^|/)(ssh-link|key-link)(/|$)'
  assert_archive_lacks "$archive" '(^|/)(config|id_rsa|authorized_keys|deep\.txt)$'
  assert_archive_has_no_escaping_links "$archive"
  end_test
}

test_existing_output_is_not_overwritten() {
  start_test "existing archive is not overwritten"
  local home="$work/existing/home"
  local project="$home/Projects/HajjUmrahApp"
  local archive="$work/existing.tar.gz"
  make_project "$project" "hajj-umrah-app"
  printf 'keep\n' >"$archive"

  run_helper "$home" --port "$UNUSED_PORT" --output "$archive"
  assert_status 1
  assert_output_contains "archive already exists"
  if [ "$(cat "$archive")" != "keep" ]; then
    fail "existing archive was modified"
  fi
  end_test
}

test_explicit_non_project_is_rejected() {
  start_test "explicit non-project is rejected"
  local home="$work/nonproject/home"
  local dir="$work/nonproject/not-a-project"
  mkdir -p "$home" "$dir"

  run_helper "$home" --project "$dir"
  assert_status 1
  assert_output_contains "not a Node project"
  end_test
}

test_common_detection_and_exclusions
test_repeatable_exclude_option
test_home_search_ambiguity
test_explicit_project_override
test_no_project_found
test_ssh_leak_is_rejected
test_symlink_outside_project_is_not_archived
test_existing_output_is_not_overwritten
test_explicit_non_project_is_rejected

if [ "$failures" -ne 0 ]; then
  printf '\n%d of %d tests failed.\n' "$failures" "$total" >&2
  exit 1
fi

printf '\nAll %d tests passed.\n' "$total"
