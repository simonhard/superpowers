#!/usr/bin/env bash
# Structural checks for the session handoff. brainstorming and writing-plans end
# with the same handoff block, the execution skills take their start as the go,
# onboard asks how a new session executes a plan, and the handoff guard teaches
# the block. Behaviour is checked by pressure scenarios; this script checks text.
#
# Usage: bash tests/session-handoff/test-handoff-structure.sh [section ...]
# Without arguments every section runs. A section is a section_* function below;
# its name on the command line uses dashes (writing-plans -> section_writing_plans).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SENTENCE="Changes? Tell me here and I'll show this block again. Otherwise, starting the next session is your go."

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

# lacks FILE NEEDLE [-i] — the repo file exists and does not contain the literal text
lacks() {
  local file="$REPO_ROOT/$1" hit=1
  if [ ! -f "$file" ]; then
    fail "$1 exists"
    return
  fi
  if [ "${3:-}" = "-i" ]; then
    grep -qiF -- "$2" "$file" && hit=0
  else
    grep -qF -- "$2" "$file" && hit=0
  fi
  if [ "$hit" -eq 0 ]; then
    fail "$1 lacks: $2"
  else
    pass "$1 lacks: $2"
  fi
}

# in_text_has LABEL TEXT NEEDLE / in_text_lacks LABEL TEXT NEEDLE — same for a block of text
in_text_has() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then
    pass "$1 contains: $3"
  else
    fail "$1 contains: $3"
  fi
}
in_text_lacks() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then
    fail "$1 lacks: $3"
  else
    pass "$1 lacks: $3"
  fi
}

# section_text FILE HEADING — "## HEADING" up to the next "## " heading
section_text() {
  awk -v h="## $2" '$0 == h {f = 1; print; next} f && /^## / {exit} f {print}' "$REPO_ROOT/$1"
}

# description_of FILE — the frontmatter description line
description_of() {
  awk 'NR == 1 && $0 != "---" {exit} NR > 1 && $0 == "---" {exit} /^description:/ {sub(/^description:[ ]*/, ""); print}' "$REPO_ROOT/$1"
}

# --- sections ---------------------------------------------------------------

section_hook() {
  local f=hooks/pre-askuser-handoff-guard
  has "$f" "$SENTENCE"
  has "$f" "/clear, then:"
  has "$f" "EXECUTION HANDOFF: no AskUserQuestion after the plan is written."
  lacks "$f" "Subagent-Driven (this session)"
  lacks "$f" "SUPERPOWERS_CONTEXT_WINDOW"
  lacks "$f" "SUPERPOWERS_HANDOFF_CTX_PCT"
}

section_writing_plans() {
  local f=skills/writing-plans/SKILL.md handoff
  has "$f" "$SENTENCE"
  has "$f" "/clear, then:"
  has "$f" "/superpowers-extended-cc:subagent-driven-development <absolute plan path>"
  has "$f" "/superpowers-extended-cc:executing-plans <absolute plan path>"
  has "$f" "parallelSession"
  has "$f" "## Starting from a spec"
  has "$f" "Ruling: <what> — <why>"
  lacks "$f" "Subagent-Driven (this session)"
  lacks "$f" "Parallel Session"
  lacks "$f" "How would you like to execute"
  lacks "$f" "manages its own completion flow via"
  handoff="$(section_text "$f" "Execution Handoff")"
  if [ -z "$handoff" ]; then
    fail "$f has section '## Execution Handoff'"
  else
    pass "$f has section '## Execution Handoff'"
    in_text_lacks "$f Execution Handoff" "$handoff" "AskUserQuestion:"
    in_text_lacks "$f Execution Handoff" "$handoff" "Invoke the Skill tool"
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
