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

# text_of_section FILE HEADING — "## HEADING" up to the next "## " heading
text_of_section() {
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
  handoff="$(text_of_section "$f" "Execution Handoff")"
  if [ -z "$handoff" ]; then
    fail "$f has section '## Execution Handoff'"
  else
    pass "$f has section '## Execution Handoff'"
    in_text_lacks "$f Execution Handoff" "$handoff" "AskUserQuestion:"
    in_text_lacks "$f Execution Handoff" "$handoff" "Invoke the Skill tool"
  fi
}

section_brainstorming() {
  local f=skills/brainstorming/SKILL.md
  has "$f" "$SENTENCE"
  has "$f" "/clear, then:"
  has "$f" "/superpowers-extended-cc:writing-plans <absolute spec path>"
  has "$f" "Hand off to a new session"
  has "$f" "I'll start the plan right here"
  lacks "$f" "TaskCreate"
  lacks "$f" "Native Task Integration"
  lacks "$f" "Invoke writing-plans skill"
  lacks "$f" "written-spec approval only permits invoking writing-plans"
}

section_subagent_driven_development() {
  local f=skills/subagent-driven-development/SKILL.md desc
  desc="$(description_of "$f")"
  in_text_has "$f description" "$desc" "started in a new session"
  in_text_lacks "$f description" "$desc" "current session"
  has "$f" "that start is the go"
  has "$f" "Routing file sets parallelSession: executing-plans?"
  lacks "$f" "Stay in this session"
  lacks "$f" "Same session (no context switch)"
}

section_executing_plans() {
  local f=skills/executing-plans/SKILL.md desc
  desc="$(description_of "$f")"
  in_text_has "$f description" "$desc" "routing file sets parallelSession to executing-plans"
  has "$f" "that start is the go"
  lacks "$f" "ListAgents"
  lacks "$f" "SendMessage"
  lacks "$f" "plan author" -i
  lacks "$f" "Ask author"
  lacks "$f" "Parallel Session"
  lacks "$f" "chose a separate session"
}

section_onboard() {
  local f=commands/onboard.md
  has "$f" "parallelSession"
  has "$f" "How should a new session execute a plan?"
  has "$f" "\"parallelSession\": \"executing-plans\""
  lacks "$f" "Parallel Session"
  lacks "$f" "Choose per plan"
}

section_docs() {
  has README.md "One phase, one session"
  lacks README.md "Architect pattern"
  lacks README.md "Subagent-Driven (this session)"
  lacks docs/model-routing-flow.md "Subagent-Driven (this session)"
  has docs/testing.md "tests/session-handoff/test-handoff-structure.sh"
  lacks tests/claude-code/test-model-routing-hook.sh "for the writing-plans menu"
  lacks tests/claude-code/test-taskcreate-tier-hook.sh "for the writing-plans menu"
}

section_leaks() {
  local f hits
  for f in skills/brainstorming/SKILL.md skills/writing-plans/SKILL.md \
           skills/subagent-driven-development/SKILL.md skills/executing-plans/SKILL.md \
           hooks/pre-askuser-handoff-guard commands/onboard.md README.md \
           docs/model-routing-flow.md docs/testing.md \
           tests/claude-code/test-handoff-guard.sh tests/claude-code/test-model-routing-hook.sh \
           tests/claude-code/test-taskcreate-tier-hook.sh; do
    hits="$(grep -nE '/Users/|/home/' "$REPO_ROOT/$f" 2>/dev/null || true)"
    if [ -z "$hits" ]; then
      pass "$f has no machine-specific paths"
    else
      fail "$f has no machine-specific paths"
      printf '%s\n' "$hits" | head -5 | sed 's/^/    /'
    fi
  done
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
