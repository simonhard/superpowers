#!/usr/bin/env bash
# Structural checks for acceptance criteria across the plugin: the
# tracing-acceptance-criteria skill itself, and the text contract in
# brainstorming, writing-plans, the two reviewer prompts, the finishing step
# and the docs. Behaviour is checked by test-trace-acceptance.sh and by
# behaviour tests; this script checks what a shell can check.
#
# Usage: bash tests/tracing-acceptance-criteria/test-skill-structure.sh [section ...]
# Without arguments every section runs; a section is a section_* function
# below, named on the command line with dashes (writing-plans).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/tracing-acceptance-criteria"
MARKER="<!-- acceptance-criteria -->"
WORD_BUDGET=1000

PASSES=0
FAILURES=0

pass() { echo "  [PASS] $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

# has FILE NEEDLE — the repo file contains the literal text
has() {
  if grep -qF -- "$2" "$REPO_ROOT/$1" 2>/dev/null; then
    pass "$1 contains: $2"
  else
    fail "$1 contains: $2"
  fi
}

# lacks FILE NEEDLE — the repo file exists and does not contain the literal text
lacks() {
  if [ ! -f "$REPO_ROOT/$1" ]; then
    fail "$1 exists"
  elif grep -qF -- "$2" "$REPO_ROOT/$1"; then
    fail "$1 lacks: $2"
  else
    pass "$1 lacks: $2"
  fi
}

# line_of FILE NEEDLE — first line number holding the literal text, 0 if none
line_of() {
  local n
  n="$(grep -nF -- "$2" "$REPO_ROOT/$1" 2>/dev/null | head -1 | cut -d: -f1)"
  echo "${n:-0}"
}

# before FILE FIRST SECOND — FIRST appears, and above SECOND
before() {
  local a b
  a="$(line_of "$1" "$2")"
  b="$(line_of "$1" "$3")"
  if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then
    pass "$1: '$2' comes before '$3'"
  else
    fail "$1: '$2' comes before '$3' (lines $a, $b)"
  fi
}

# --- sections ---------------------------------------------------------------

section_tracing() {
  local f="$SKILL_DIR/SKILL.md" frontmatter description body_words ref ph count
  if [ ! -f "$f" ]; then
    fail "SKILL.md exists"
    return
  fi
  pass "SKILL.md exists"
  frontmatter="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$f")"
  if printf '%s\n' "$frontmatter" | grep -q '^name: tracing-acceptance-criteria$'; then
    pass "frontmatter name is tracing-acceptance-criteria"
  else
    fail "frontmatter name is tracing-acceptance-criteria"
  fi
  description="$(printf '%s\n' "$frontmatter" | awk '/^description:/{sub(/^description:[ ]*/,""); print}')"
  if printf '%s' "$description" | grep -q '^Use when'; then
    pass "description starts with 'Use when'"
  else
    fail "description starts with 'Use when' (got: ${description:0:60})"
  fi
  for banned in dispatch "then" step; do
    if printf '%s' "$description" | grep -qiw "$banned"; then
      fail "description avoids workflow word '$banned'"
    else
      pass "description avoids workflow word '$banned'"
    fi
  done

  body_words="$(awk 'BEGIN{fm=0} NR==1 && $0=="---"{fm=1; next} fm==1 && $0=="---"{fm=2; next} fm==2{print}' "$f" | wc -w | tr -d ' ')"
  if [ "$body_words" -le "$WORD_BUDGET" ]; then
    pass "SKILL.md body within $WORD_BUDGET words ($body_words)"
  else
    fail "SKILL.md body within $WORD_BUDGET words ($body_words)"
  fi

  for heading in "## The table" "## Writing criteria (define)" "## Tracing (trace)" \
                 "## Showing the overview" "## Hard rules" "## Red Flags"; do
    if grep -qxF "$heading" "$f"; then
      pass "SKILL.md has section '$heading'"
    else
      fail "SKILL.md has section '$heading'"
    fi
  done
  has skills/tracing-acceptance-criteria/SKILL.md "$MARKER"
  has skills/tracing-acceptance-criteria/SKILL.md 'Level: `API`, `UI`, `CLI`, `unit` or `manual`'

  while IFS= read -r ref; do
    if [ -f "$SKILL_DIR/$ref" ]; then
      pass "referenced file exists: $ref"
    else
      fail "referenced file exists: $ref"
    fi
  done < <(grep -o '\(scripts\|templates\)/[A-Za-z0-9._-]*\.\(sh\|html\)' "$f" | sort -u)

  for ph in TITLE SUBTITLE COUNTS CRITERIA UNMAPPED; do
    count="$(grep -o "{{$ph}}" "$SKILL_DIR/templates/acceptance-overview.html" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$count" = "1" ]; then
      pass "template placeholder {{$ph}} appears once"
    else
      fail "template placeholder {{$ph}} appears once (found $count)"
    fi
  done
  has skills/tracing-acceptance-criteria/templates/acceptance-overview.html "prefers-color-scheme: dark"
}

section_brainstorming() {
  local f=skills/brainstorming/SKILL.md
  has "$f" "$MARKER"
  has "$f" "Criteria your"
  has "$f" "acceptance criteria with test names, testing"
  has "$f" "at the end, list each criterion → test name → file"
  has "$f" "6. **Present acceptance criteria** — their own design section, written with the tracing-acceptance-criteria skill (define mode)"
  has "$f" "10. **Hand off to a new session**"
  has "$f" '"User approves design?" -> "Present acceptance criteria" [label="yes"];'
  lacks "$f" '"User approves design?" -> "Write design doc\n+ architecture delta" [label="yes"];'
  before "$f" "**Acceptance Criteria:**" "**Architecture Delta:**"
  has "$f" "6. **Criteria check:**"
  has "$f" "the acceptance criteria are in section <n>"
  has "$f" "They named no criteria, so there are none"
  has "$f" "I'll phrase their criterion a little more precisely"
}

section_writing_plans() {
  local f=skills/writing-plans/SKILL.md
  has "$f" "$MARKER"
  has "$f" "**Acceptance criteria.** When the spec has the table"
  has "$f" "The names in the spec are binding."
  has "$f" '- AC-1 [criterion sentence from the spec] → `[testName]` ([level])'
  before "$f" "**Acceptance tests:** *(only when the spec has acceptance criteria)*" "**Verify:** \`exact test command\`"
  has "$f" "**5. Acceptance coverage:**"
}

section_reviewers() {
  local t=skills/subagent-driven-development/task-reviewer-prompt.md c=skills/requesting-code-review/code-reviewer.md
  has "$t" "    ## Acceptance Tests"
  has "$t" "If the brief has lines under **Acceptance tests**"
  has "$t" 'except those of level `manual`'
  before "$t" "    ## Acceptance Tests" "    ## Part 2: Code Quality"
  has "$c" "$MARKER"
  has "$c" "**Acceptance tests** (when the plan's \`Spec:\` line names a spec"
  for f in "$t" "$c"; do
    has "$f" "A direct call"
    has "$f" "A violation is Important and names the criterion's ID."
  done
}

section_finishing() {
  local f=skills/finishing-a-development-branch/SKILL.md
  has "$f" "→ Show architecture delta → Accept criteria → Present options →"
  before "$f" "## Step 4: Show the Architecture Delta" "## Step 5: Accept the Criteria"
  before "$f" "## Step 5: Accept the Criteria" "## Step 6: Present Options"
  before "$f" "## Step 6: Present Options" "## Step 7: Execute Choice"
  before "$f" "## Step 7: Execute Choice" "## Step 8: Cleanup Workspace"
  lacks "$f" "## Step 5: Present Options"
  lacks "$f" "(Step 7)"
  has "$f" "invoke the tracing-acceptance-criteria skill in **trace** mode"
  has "$f" "or no spec at all (bounded work)"
  has "$f" "No menu in the same"
  has "$f" "Tests are green, they'll accept anyway"
}

section_docs() {
  has README.md "## Acceptance Criteria"
  has README.md "(#acceptance-criteria)"
  has README.md "- **tracing-acceptance-criteria** -"
  has README.md "waits for your acceptance, then presents options"
  has docs/testing.md "tests/tracing-acceptance-criteria/"
}

section_leaks() {
  local hits f
  hits="$(grep -rniE '/Users/|/home/|simon' "$SKILL_DIR" "$SCRIPT_DIR" --exclude=test-skill-structure.sh 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "no machine-specific paths or private names in the new skill and its tests"
  else
    fail "no machine-specific paths or private names in the new skill and its tests"
    printf '%s\n' "$hits" | head -10 | sed 's/^/    /'
  fi
  for f in skills/brainstorming/SKILL.md skills/writing-plans/SKILL.md \
           skills/subagent-driven-development/task-reviewer-prompt.md \
           skills/requesting-code-review/code-reviewer.md \
           skills/finishing-a-development-branch/SKILL.md README.md docs/testing.md; do
    hits="$(grep -nE '/Users/|/home/' "$REPO_ROOT/$f" 2>/dev/null || true)"
    if [ -z "$hits" ]; then
      pass "$f has no machine-specific paths"
    else
      fail "$f has no machine-specific paths"
      printf '%s\n' "$hits" | head -5 | sed 's/^/    /'
    fi
  done
  hits="$(grep -rn -i 'the user' "$SKILL_DIR" --include='*.md' --include='*.html' 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "skill files say 'your human partner', not 'the user'"
  else
    fail "skill files say 'your human partner', not 'the user'"
    printf '%s\n' "$hits" | head -10 | sed 's/^/    /'
  fi
}

# --- dispatcher: every section_* function above is one section --------------

names=()
if [ "$#" -gt 0 ]; then
  names=("$@")
else
  while IFS= read -r name; do
    names+=("$name")
  done < <(declare -F | awk '$3 ~ /^section_/ {sub(/^section_/, "", $3); gsub(/_/, "-", $3); print $3}')
fi

for name in "${names[@]}"; do
  fn="section_${name//-/_}"
  echo "== $name"
  if declare -F "$fn" >/dev/null; then
    "$fn"
  else
    fail "unknown section: $name"
  fi
done

echo
echo "Passed: $PASSES  Failed: $FAILURES"
[ "$FAILURES" -eq 0 ]
