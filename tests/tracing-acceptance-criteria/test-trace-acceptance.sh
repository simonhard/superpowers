#!/usr/bin/env bash
# Behaviour tests for skills/tracing-acceptance-criteria/scripts/trace-acceptance.sh.
# Every case builds a throwaway git repo with a spec and test files, runs the
# script and compares its output byte for byte. Each case is one function
# named like the test names in the package's spec; the runner at the bottom
# calls every function whose name starts with "it".
#
# Two rules keep this file honest when the script scans it (it holds the
# package's own acceptance tests):
# - Fixture test files are written with the prefix Q_ on every declaration
#   (Q_it(, Q_test(, Q_function, Q_def); put() strips it. So no line of this
#   file looks like a test declaration except the cases themselves.
# - The line above each case and its first two body lines carry no skip marker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRACE="$REPO_ROOT/skills/tracing-acceptance-criteria/scripts/trace-acceptance.sh"

FAILURES=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tab="$(printf '\t')"

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

assert_equal() {
  if [ "$1" == "$2" ]; then
    pass "$3"
  else
    fail "$3"
    echo "    expected:"; printf '%s\n' "$1" | sed 's/^/      /'
    echo "    actual:";   printf '%s\n' "$2" | sed 's/^/      /'
  fi
}

assert_contains() {
  if printf '%s' "$1" | grep -Fq -- "$2"; then
    pass "$3"
  else
    fail "$3"
    echo "    expected to find: $2"
    printf '%s\n' "$1" | sed 's/^/      /'
  fi
}

# new_repo DIR — a git repo with one empty commit on main
new_repo() {
  git init -q -b main "$1"
  git -C "$1" config user.name "Test Bot"
  git -C "$1" config user.email "test@example.com"
  git -C "$1" commit -q --allow-empty -m "start"
}

# put DIR PATH — write stdin to DIR/PATH, stripping the Q_ mask
put() {
  mkdir -p "$(dirname "$1/$2")"
  sed 's/Q_//g' >"$1/$2"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# run_in DIR ARGS... — sets OUT (stdout), ERR (stderr) and RC; never aborts
run_in() {
  local dir="$1"
  shift
  RC=0
  OUT="$(cd "$dir" && bash "$TRACE" "$@" 2>"$TMP/stderr")" || RC=$?
  ERR="$(cat "$TMP/stderr")"
}

# spec_with ROW... — a spec whose table holds the given rows
spec_with() {
  printf '# Login — design\n\n## Acceptance criteria\n\n<!-- acceptance-criteria -->\n'
  printf '| ID | Criterion | Origin | Level | Tests |\n|---|---|---|---|---|\n'
  printf '%s\n' "$@"
  printf '\n**AC-1** — Given: a user "ana". When: she logs in. Then: the start page greets "ana".\n'
}

login_php() {
  put "$1" tests/LoginTest.php <<'EOF'
<?php
final class LoginTest extends TestCase
{
    public Q_function itLogsAUserInAndRefreshes(): void
    {
        $this->assertTrue(login('ana', 'secret'));
    }

    public Q_function itKeepsTheSessionAfterReload(): void
    {
        $this->assertSame('ana', reload());
    }
}
EOF
}

skip_fixtures() {
  put "$1" tests/login.spec.js <<'EOF'
describe('login', () => {
  Q_it.skip('remembers the last user', () => {});
  process.exit(0);
  Q_it('keeps the session after reload', () => {});
});
EOF
  put "$1" tests/test_checkout.py <<'EOF'
import pytest

@pytest.mark.skip(reason="gateway down")
Q_def test_charges_the_card():
    assert charge(10) == "ok"
EOF
  put "$1" tests/ReceiptTest.php <<'EOF'
<?php
final class ReceiptTest extends TestCase
{
    public Q_function itSendsAReceipt(): void
    {
        $this->markTestSkipped('mail server down');
    }
}
EOF
}

# --- cases ------------------------------------------------------------------

itListsEachCriterionWithItsTests() {
  local r="$TMP/lists"
  new_repo "$r"
  spec_with \
    '| AC-1 | A user logs in and the session refreshes | partner | API | `itLogsAUserInAndRefreshes`, `itKeepsTheSessionAfterReload` |' \
    '| AC-2 | After logout the start page shows "Login \| Register" | proposal | UI | `itRedirectsToStart` |' \
    | put "$r" docs/superpowers/specs/2026-01-01-login-design.md
  login_php "$r"
  put "$r" e2e/logout.js <<'EOF'
// logout flow
Q_function itRedirectsToStart() {}
EOF
  put "$r" tests/helpers/session.php <<'EOF'
<?php
// shared by itKeepsTheSessionAfterReload
EOF
  put "$r" src/login.php <<'EOF'
<?php
// covered by itLogsAUserInAndRefreshes
EOF
  put "$r" docs/superpowers/plans/2026-01-01-login-tests.md <<'EOF'
- AC-1 → `itLogsAUserInAndRefreshes`, `itKeepsTheSessionAfterReload`; AC-2 → `itRedirectsToStart`
EOF
  put "$r" docs/superpowers/plans/2026-01-01-login-tests.md.tasks.json <<'EOF'
{"tasks": [{"description": "itLogsAUserInAndRefreshes itKeepsTheSessionAfterReload itRedirectsToStart"}]}
EOF
  commit_all "$r" "login"

  local expected="#criterion${tab}AC-1${tab}partner${tab}API${tab}A user logs in and the session refreshes
AC-1${tab}found${tab}itLogsAUserInAndRefreshes${tab}tests/LoginTest.php:4${tab}1
AC-1${tab}found${tab}itKeepsTheSessionAfterReload${tab}tests/LoginTest.php:9${tab}2
#criterion${tab}AC-2${tab}proposal${tab}UI${tab}After logout the start page shows \"Login | Register\"
AC-2${tab}found${tab}itRedirectsToStart${tab}e2e/logout.js:2${tab}1
#counts${tab}criteria=2${tab}tests=3${tab}found=3${tab}missing=0${tab}skipped=0${tab}manual=0${tab}unmapped=0"

  run_in "$r" --spec docs/superpowers/specs/2026-01-01-login-design.md
  assert_equal 0 "$RC" "lists: exits 0"
  assert_equal "$expected" "$OUT" "lists: every criterion with its tests, first hit, hit count, escaped pipe; Markdown, .tasks.json and non-test files never count"
  run_in "$r/src" --spec ../docs/superpowers/specs/2026-01-01-login-design.md
  assert_equal "$expected" "$OUT" "lists: same output when run from a subdirectory"
  awk '{printf "%s\r\n", $0}' "$r/docs/superpowers/specs/2026-01-01-login-design.md" >"$TMP/crlf.md"
  run_in "$r" --spec "$TMP/crlf.md"
  assert_equal "$expected" "$OUT" "lists: same output for a spec saved with CRLF line endings"
  {
    cat "$r/docs/superpowers/specs/2026-01-01-login-design.md"
    printf '\n```markdown\n<!-- acceptance-criteria -->\n| ID | Criterion | Origin | Level | Tests |\n'
    printf '|---|---|---|---|---|\n| AC-9 | An example | partner | API | `itIsOnlyAnExample` |\n```\n'
  } >"$TMP/fenced.md"
  run_in "$r" --spec "$TMP/fenced.md"
  assert_equal "$expected" "$OUT" "lists: a format example in a code fence after the table is ignored"
}

itReportsACriterionWithoutTest() {
  local r="$TMP/without"
  new_repo "$r"
  spec_with \
    '| AC-1 | A user logs in and the session refreshes | partner | API | `itLogsAUserInAndRefreshes` |' \
    '| AC-2 | A wrong password shows an error | proposal | API | `itShowsAnError` |' \
    | put "$r" docs/spec.md
  login_php "$r"
  put "$r" src/errors.js <<'EOF'
// see itShowsAnError
EOF
  put "$r" src/specials/inspector_latest.js <<'EOF'
// see itShowsAnError
EOF
  mkdir -p "$r/tests/fixtures"
  printf 'itShowsAnError\000binary\n' >"$r/tests/fixtures/blob.bin"
  git -C "$r" config color.ui always
  commit_all "$r" "login"

  run_in "$r" --spec docs/spec.md
  assert_contains "$OUT" "AC-2${tab}missing${tab}itShowsAnError${tab}-${tab}0" "without test: missing, no place, zero hits (a mention outside test files does not count, nor in look-alike paths such as inspector/latest/specials, nor in a binary file, nor with color.ui=always)"
  assert_contains "$OUT" "#counts${tab}criteria=2${tab}tests=2${tab}found=1${tab}missing=1${tab}skipped=0${tab}manual=0${tab}unmapped=0" "without test: counted as missing"
}

itMarksASkippedTest() {
  local r="$TMP/skipped"
  new_repo "$r"
  spec_with \
    '| AC-1 | The last user is remembered | partner | UI | `remembers the last user`, `keeps the session after reload` |' \
    '| AC-2 | A paid order gets a receipt | proposal | API | `test_charges_the_card`, `itSendsAReceipt` |' \
    | put "$r" docs/spec.md
  skip_fixtures "$r"
  commit_all "$r" "fixtures"

  run_in "$r" --spec docs/spec.md
  assert_contains "$OUT" "AC-1${tab}skipped${tab}remembers the last user${tab}tests/login.spec.js:2${tab}1" "skipped: marker on the hit line (.skip()"
  assert_contains "$OUT" "AC-1${tab}found${tab}keeps the session after reload${tab}tests/login.spec.js:4${tab}1" "skipped: exit( on the line above is no marker"
  assert_contains "$OUT" "AC-2${tab}skipped${tab}test_charges_the_card${tab}tests/test_checkout.py:4${tab}1" "skipped: marker on the line above (pytest.mark.skip)"
  assert_contains "$OUT" "AC-2${tab}skipped${tab}itSendsAReceipt${tab}tests/ReceiptTest.php:4${tab}1" "skipped: body marker two lines below (markTestSkipped)"
  assert_contains "$OUT" "#counts${tab}criteria=2${tab}tests=4${tab}found=1${tab}missing=0${tab}skipped=3${tab}manual=0${tab}unmapped=0" "skipped: counts"
}

itReportsANewTestWithoutCriterion() {
  local r="$TMP/unmapped"
  new_repo "$r"
  spec_with '| AC-1 | A user logs in and the session refreshes | partner | API | `logs a user in and refreshes`, `keeps the session after reload` |' \
    | put "$r" docs/spec.md
  put "$r" tests/login.spec.js <<'EOF'
describe('login', () => {
  Q_it('logs a user in and refreshes', () => {});
});
EOF
  put "$r" tests/search.spec.js <<'EOF'
Q_it('finds an order', () => {});
EOF
  commit_all "$r" "base"
  git -C "$r" checkout -q -b feature
  put "$r" tests/login.spec.js <<'EOF'
describe('login', () => {
  Q_it('logs a user in and refreshes', () => {});
  Q_it('keeps the session after reload', () => {});
  Q_it('logs out after an hour', () => {});
});
EOF
  put "$r" tests/search.spec.js <<'EOF'
Q_it('finds an order', () => {});
Q_it('sorts by date', () => {});
EOF
  commit_all "$r" "more tests"

  run_in "$r" --spec docs/spec.md --base main
  assert_equal 0 "$RC" "unmapped: exits 0"
  assert_equal "#criterion${tab}AC-1${tab}partner${tab}API${tab}A user logs in and the session refreshes
AC-1${tab}found${tab}logs a user in and refreshes${tab}tests/login.spec.js:2${tab}1
AC-1${tab}found${tab}keeps the session after reload${tab}tests/login.spec.js:3${tab}1
#unmapped${tab}logs out after an hour${tab}tests/login.spec.js:4
#counts${tab}criteria=1${tab}tests=2${tab}found=2${tab}missing=0${tab}skipped=0${tab}manual=0${tab}unmapped=1" "$OUT" \
    "unmapped: a new test in a file with a named test is reported; a file without one is not"
  run_in "$r" --spec docs/spec.md
  assert_contains "$OUT" "unmapped=0" "unmapped: without --base nothing is reported"
}

itSaysSoWhenTheSpecHasNoCriteria() {
  local r="$TMP/nocriteria"
  new_repo "$r"
  printf '# Old design\n\nNo criteria here.\n' | put "$r" docs/old-design.md
  {
    printf '# Format example\n\n```markdown\n<!-- acceptance-criteria -->\n'
    printf '| ID | Criterion | Origin | Level | Tests |\n|---|---|---|---|---|\n```\n'
  } | put "$r" docs/fenced.md
  commit_all "$r" "docs"

  run_in "$r" --spec docs/old-design.md
  assert_equal 3 "$RC" "no criteria: exits 3"
  assert_equal "no acceptance criteria in docs/old-design.md" "$OUT" "no criteria: one sentence on stdout naming the spec"
  run_in "$r" --spec docs/fenced.md
  assert_equal 3 "$RC" "no criteria: a marker inside a code fence does not count"
}

itStopsOnABrokenTable() {
  local r="$TMP/broken"
  new_repo "$r"
  spec_with '| AC-1 | A user logs in | partner | API |' | put "$r" docs/columns.md
  spec_with '| AC-1 | A user logs in | partner | E2E | `itLogsIn` |' | put "$r" docs/level.md
  printf '# Spec\n\n<!-- acceptance-criteria -->\n\n| ID | Criterion | Origin | Level | Tests |\n' | put "$r" docs/gap.md
  commit_all "$r" "specs"

  run_in "$r" --spec docs/columns.md
  assert_equal 2 "$RC" "broken: wrong column count exits 2"
  assert_contains "$ERR" "docs/columns.md:8: expected 5 columns, found 4" "broken: names the line and the column count"
  assert_equal "" "$OUT" "broken: no overview on stdout"
  run_in "$r" --spec docs/level.md
  assert_equal 2 "$RC" "broken: unknown level exits 2"
  assert_contains "$ERR" "unknown level \"E2E\"" "broken: names the unknown level"
  run_in "$r" --spec docs/gap.md
  assert_equal 2 "$RC" "broken: a blank line between marker and header exits 2"
  assert_contains "$ERR" "docs/gap.md:4: the marker must stand directly above the table header" "broken: names the line after the marker"
}

itRejectsADuplicateId() {
  local r="$TMP/duplicate"
  new_repo "$r"
  spec_with \
    '| AC-1 | A user logs in | partner | API | `itLogsIn` |' \
    '| AC-1 | A user logs out | proposal | API | `itLogsOut` |' \
    | put "$r" docs/spec.md
  commit_all "$r" "spec"

  run_in "$r" --spec docs/spec.md
  assert_equal 2 "$RC" "duplicate: exits 2"
  assert_contains "$ERR" "docs/spec.md:9: duplicate id AC-1 (first at line 8)" "duplicate: names both lines"
  assert_equal "" "$OUT" "duplicate: no overview on stdout"
}

itIgnoresManualRows() {
  local r="$TMP/manual"
  new_repo "$r"
  spec_with '| AC-1 | Support can read the audit log | partner | manual | Behaviour check P1 `itChecksByHand` |' \
    | put "$r" docs/spec.md
  put "$r" tests/audit.spec.js <<'EOF'
Q_function itChecksByHand() {}
EOF
  commit_all "$r" "manual"

  run_in "$r" --spec docs/spec.md
  assert_equal "#criterion${tab}AC-1${tab}partner${tab}manual${tab}Support can read the audit log
AC-1${tab}manual${tab}Behaviour check P1 \`itChecksByHand\`${tab}-${tab}0
#counts${tab}criteria=1${tab}tests=1${tab}found=0${tab}missing=0${tab}skipped=0${tab}manual=1${tab}unmapped=0" "$OUT" \
    "manual: the Tests cell is printed as is and never searched"
}

itFindsStringNamedTests() {
  local r="$TMP/strings"
  new_repo "$r"
  spec_with '| AC-1 | A user logs in and the session refreshes | partner | API | `logs a user in`, `keeps the session after reload` |' \
    '| AC-2 | The UI greets the user | proposal | UI | `greets in the UI suite` |' \
    | put "$r" docs/spec.md
  put "$r" App/LoginUITests.swift <<'EOF'
Q_it("greets in the UI suite", () => {});
EOF
  put "$r" tests/login.spec.js <<'EOF'
describe('login', () => {
  Q_it('logs a user in with single sign-on', () => {});
  Q_it('logs a user in', () => {});
  Q_test("keeps the session after reload", () => {});
});
EOF
  commit_all "$r" "strings"

  run_in "$r" --spec docs/spec.md
  assert_contains "$OUT" "AC-1${tab}found${tab}logs a user in${tab}tests/login.spec.js:3${tab}1" "strings: single quotes, a longer name with the same start does not match"
  assert_contains "$OUT" "AC-1${tab}found${tab}keeps the session after reload${tab}tests/login.spec.js:4${tab}1" "strings: double quotes"
  assert_contains "$OUT" "AC-2${tab}found${tab}greets in the UI suite${tab}App/LoginUITests.swift:1${tab}1" "strings: a camelCase token with capitals (LoginUITests) marks a test path"
}

itHandlesANonAsciiPath() {
  local r="$TMP/nonascii"
  new_repo "$r"
  spec_with '| AC-1 | Die Übersicht zeigt alle Aufträge | Dana | UI | `zeigt die Übersicht` |' \
    | put "$r" "docs/Spezifikation Übersicht.md"
  put "$r" "tests/Übersicht/übersicht.test.js" <<'EOF'
Q_it('zeigt die Übersicht', () => {});
EOF
  commit_all "$r" "base"
  git -C "$r" checkout -q -b feature
  put "$r" "tests/Übersicht/übersicht.test.js" <<'EOF'
Q_it('zeigt die Übersicht', () => {});
Q_it('zeigt die Summe', () => {});
++ count;
Q_it('zeigt den Rest', () => {});
EOF
  commit_all "$r" "sum"

  run_in "$r" --spec "docs/Spezifikation Übersicht.md" --base main
  assert_equal 0 "$RC" "non-ascii: exits 0"
  assert_contains "$OUT" "AC-1${tab}found${tab}zeigt die Übersicht${tab}tests/Übersicht/übersicht.test.js:1${tab}1" "non-ascii: the path is printed verbatim"
  assert_contains "$OUT" "#unmapped${tab}zeigt die Summe${tab}tests/Übersicht/übersicht.test.js:2" "non-ascii: tests without criterion are found in that file"
  assert_contains "$OUT" "#unmapped${tab}zeigt den Rest${tab}tests/Übersicht/übersicht.test.js:4" "non-ascii: an added line starting with ++ does not shift later line numbers"
}

itStopsOnAnUnknownBase() {
  local r="$TMP/base"
  new_repo "$r"
  spec_with '| AC-1 | A user logs in | partner | API | `itLogsIn` |' | put "$r" docs/spec.md
  commit_all "$r" "spec"

  run_in "$r" --spec docs/spec.md --base no-such-branch
  assert_equal 2 "$RC" "unknown base: exits 2"
  assert_contains "$ERR" "unknown ref for --base: no-such-branch" "unknown base: names the ref"
  assert_equal "" "$OUT" "unknown base: no overview on stdout"
  git -C "$r" branch unrelated "$(git -C "$r" commit-tree -m "unrelated root" "$(git -C "$r" hash-object -t tree /dev/null)")"
  run_in "$r" --spec docs/spec.md --base unrelated
  assert_equal 2 "$RC" "unknown base: a base without a merge base exits 2"
  assert_contains "$ERR" "no merge base" "unknown base: says there is no merge base"
  assert_equal "" "$OUT" "unknown base: no merge base leaves stdout empty"
}

itStopsOnAMissingSpec() {
  local r="$TMP/missing"
  new_repo "$r"
  run_in "$r"
  assert_equal 2 "$RC" "missing spec: no --spec exits 2"
  assert_contains "$ERR" "Usage:" "missing spec: prints usage"
  run_in "$r" --spec docs/nope.md
  assert_equal 2 "$RC" "missing spec: a path that does not exist exits 2"
  assert_contains "$ERR" "spec not found: docs/nope.md" "missing spec: names the path"
  spec_with '| AC-1 | A user logs in | partner | API | `itLogsIn` |' >"$r/locked.md"
  chmod 000 "$r/locked.md"
  if [ -r "$r/locked.md" ]; then
    echo "  note: spec stays readable after chmod (root), unreadable-spec check skipped"
  else
    run_in "$r" --spec locked.md
    assert_equal 2 "$RC" "missing spec: an unreadable spec exits 2"
    assert_contains "$ERR" "spec not readable" "missing spec: says it is not readable"
  fi
  chmod 644 "$r/locked.md"
  mkdir -p "$TMP/plain"
  spec_with '| AC-1 | A user logs in | partner | API | `itLogsIn` |' >"$TMP/plain/spec.md"
  run_in "$TMP/plain" --spec spec.md
  assert_equal 2 "$RC" "missing spec: outside a git work tree exits 2"
  assert_contains "$ERR" "not inside a git work tree" "missing spec: says why"
}

# --- runner -----------------------------------------------------------------

echo "trace-acceptance tests"
for case_name in $(declare -F | awk '$3 ~ /^it[A-Z]/ {print $3}'); do
  echo "== $case_name"
  "$case_name"
done

if [ "$FAILURES" -eq 0 ]; then
  echo "All trace-acceptance tests passed"
else
  echo "$FAILURES trace-acceptance test(s) failed"
  exit 1
fi
