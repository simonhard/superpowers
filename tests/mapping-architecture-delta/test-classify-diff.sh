#!/usr/bin/env bash
# Behaviour tests for skills/mapping-architecture-delta/scripts/classify-diff.sh.
# Builds a throwaway git repo with a map file, makes one commit holding every
# change kind, and compares the script's output byte for byte.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/skills/mapping-architecture-delta/scripts/classify-diff.sh"

FAILURES=0
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

assert_equal() {
  local expected="$1" actual="$2" description="$3"
  if [ "$expected" == "$actual" ]; then
    pass "$description"
  else
    fail "$description"
    echo "    expected:"; printf '%s\n' "$expected" | sed 's/^/      /'
    echo "    actual:";   printf '%s\n' "$actual"   | sed 's/^/      /'
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$description"
  else
    fail "$description"
    echo "    expected to find: $needle"
    printf '%s\n' "$haystack" | sed 's/^/      /'
  fi
}

write_map() {
  cat >"$1" <<'EOF'
# Architecture map — fixture

Longest path prefix wins. Blocks with zone `—` appear only in the repository view.

| Prefix          | Block            | Zone            |
|-----------------|------------------|-----------------|
| server/         | Server (Rust)    | Host            |
| deploy/         | Deploy scripts   | Operator's Mac  |
| deploy/ansible/ | Ansible playbook | Operator's Mac  |
| README.md       | Documentation    | —               |
| docs/           | Documentation    | —               |

| From          | To            | Label |
|---------------|---------------|-------|
| Server (Rust) | Postgres      | SQL   |
EOF
}

# make_repo <dir> <with-map: yes|no>
make_repo() {
  local repo="$1" with_map="$2"
  git init -q -b main "$repo"
  git -C "$repo" config user.name "Test Bot"
  git -C "$repo" config user.email "test@example.com"
  mkdir -p "$repo/server" "$repo/docs/superpowers" "$repo/deploy/scripts"
  echo 'fn a() {}' >"$repo/server/a.rs"
  echo 'fn old() {}' >"$repo/server/old.rs"
  echo '# Fixture' >"$repo/README.md"
  echo 'echo deploy' >"$repo/deploy/scripts/deploy.sh"
  if [ "$with_map" = yes ]; then
    write_map "$repo/docs/superpowers/architecture-map.md"
  fi
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "base"
  git -C "$repo" branch -q base

  mkdir -p "$repo/deploy/ansible" "$repo/tools" "$repo/server-tools"
  echo 'hosts: all' >"$repo/deploy/ansible/site.yml"
  echo 'more' >>"$repo/README.md"
  git -C "$repo" rm -q server/old.rs
  git -C "$repo" mv server/a.rs server/b.rs
  echo 'x' >"$repo/tools/x.sh"
  echo 'y' >"$repo/server-tools/x.rs"
  echo 'über' >"$repo/docs/Übersicht.md"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "changes"
}

# run_in <dir> <args...> — sets OUTPUT and RC, never aborts the test
run_in() {
  local dir="$1"; shift
  RC=0
  OUTPUT="$(cd "$dir" && bash "$SCRIPT_UNDER_TEST" "$@" 2>&1)" || RC=$?
}

tab="$(printf '\t')"
expected_full="M${tab}README.md${tab}Documentation${tab}-
A${tab}deploy/ansible/site.yml${tab}Ansible playbook${tab}Operator's Mac
A${tab}docs/Übersicht.md${tab}Documentation${tab}-
A${tab}server-tools/x.rs${tab}?${tab}-
R${tab}server/a.rs -> server/b.rs${tab}Server (Rust)${tab}Host
D${tab}server/old.rs${tab}Server (Rust)${tab}Host
A${tab}tools/x.sh${tab}?${tab}-
#counts${tab}added=4${tab}modified=1${tab}deleted=1${tab}renamed=1${tab}unmapped=2
#unmapped${tab}server-tools/x.rs
#unmapped${tab}tools/x.sh"

echo "classify-diff tests"

mapped="$TEST_ROOT/mapped"
make_repo "$mapped" yes

run_in "$mapped" --base base
assert_equal 0 "$RC" "full run exits 0"
assert_equal "$expected_full" "$OUTPUT" "full run: statuses, longest prefix, rename label, utf-8 path, sibling prefix unmapped, counts, #unmapped"

sed 's/$/\r/' "$mapped/docs/superpowers/architecture-map.md" >"$TEST_ROOT/map-crlf.md"
run_in "$mapped" --base base --map "$TEST_ROOT/map-crlf.md"
assert_equal "$expected_full" "$OUTPUT" "explicit --map with CRLF line endings gives the same output"

run_in "$mapped" --base HEAD
assert_equal "#counts${tab}added=0${tab}modified=0${tab}deleted=0${tab}renamed=0${tab}unmapped=0" "$OUTPUT" "empty diff prints a zero counts row only"

unmapped_repo="$TEST_ROOT/unmapped"
make_repo "$unmapped_repo" no
run_in "$unmapped_repo" --base base
assert_equal 0 "$RC" "run without map file exits 0"
assert_contains "$OUTPUT" "#counts${tab}added=4${tab}modified=1${tab}deleted=1${tab}renamed=1${tab}unmapped=7" "without map every path is unmapped"
non_question="$(printf '%s\n' "$OUTPUT" | awk -F '\t' '!/^#/ && $3 != "?"' | wc -l | tr -d ' ')"
assert_equal 0 "$non_question" "without map every block is ?"

run_in "$mapped"
assert_equal 2 "$RC" "missing --base exits 2"
assert_contains "$OUTPUT" "Usage:" "missing --base prints usage"

run_in "$mapped" --base no-such-branch
assert_equal 2 "$RC" "unknown base ref exits 2"
assert_contains "$OUTPUT" "no-such-branch" "unknown base ref is named"

run_in "$mapped" --base base --map "$TEST_ROOT/does-not-exist.md"
assert_equal 2 "$RC" "explicit missing --map exits 2"

plain="$TEST_ROOT/plain"
mkdir -p "$plain"
run_in "$plain" --base main
assert_equal 2 "$RC" "outside a git work tree exits 2"

if [ "$FAILURES" -eq 0 ]; then
  echo "All classify-diff tests passed"
else
  echo "$FAILURES classify-diff test(s) failed"
  exit 1
fi
