#!/usr/bin/env bash
# Structural checks for skills/mapping-architecture-delta. Behaviour is checked
# by the classify-diff test and by pressure scenarios; this script checks what
# a shell can check: frontmatter, word budget, required sections, referenced
# files, template placeholders, local paths, voice.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/mapping-architecture-delta"
SKILL_MD="$SKILL_DIR/SKILL.md"
WORD_BUDGET=900

PASSES=0
FAILURES=0

pass() { echo "  [PASS] $1"; PASSES=$((PASSES + 1)); }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }

echo "mapping-architecture-delta structure"

# --- SKILL.md frontmatter -------------------------------------------------
if [ -f "$SKILL_MD" ]; then
  pass "SKILL.md exists"
  frontmatter="$(awk 'NR==1 && $0!="---"{exit} NR>1 && $0=="---"{exit} NR>1{print}' "$SKILL_MD")"
  if printf '%s\n' "$frontmatter" | grep -q '^name: mapping-architecture-delta$'; then
    pass "frontmatter name is mapping-architecture-delta"
  else
    fail "frontmatter name is mapping-architecture-delta"
  fi
  description="$(printf '%s\n' "$frontmatter" | awk '/^description:/{sub(/^description:[ ]*/,""); print; found=1; next} found && /^[ ]/{print} found && !/^[ ]/{exit}' | tr '\n' ' ')"
  if printf '%s' "$description" | grep -q '^Use when'; then
    pass "description starts with 'Use when'"
  else
    fail "description starts with 'Use when' (got: ${description:0:60})"
  fi
  if [ "${#description}" -le 1024 ]; then
    pass "description under 1024 characters"
  else
    fail "description under 1024 characters (${#description})"
  fi
  for banned in "dispatch" "then" "step"; do
    if printf '%s' "$description" | grep -qiw "$banned"; then
      fail "description contains workflow word '$banned'"
    else
      pass "description avoids workflow word '$banned'"
    fi
  done

  # --- word budget --------------------------------------------------------
  body_words="$(awk 'BEGIN{fm=0} NR==1 && $0=="---"{fm=1; next} fm==1 && $0=="---"{fm=2; next} fm==2{print}' "$SKILL_MD" | wc -w | tr -d ' ')"
  if [ "$body_words" -le "$WORD_BUDGET" ]; then
    pass "SKILL.md body within $WORD_BUDGET words ($body_words)"
  else
    fail "SKILL.md body within $WORD_BUDGET words ($body_words)"
  fi

  # --- required sections --------------------------------------------------
  for heading in "## Hard rules" "## Red Flags"; do
    if grep -q "^$heading" "$SKILL_MD"; then
      pass "SKILL.md has section '$heading'"
    else
      fail "SKILL.md has section '$heading'"
    fi
  done

  # --- every referenced skill file exists --------------------------------
  while IFS= read -r ref; do
    if [ -f "$SKILL_DIR/$ref" ]; then
      pass "referenced file exists: $ref"
    else
      fail "referenced file exists: $ref"
    fi
  done < <(grep -o '\(references\|templates\|scripts\)/[A-Za-z0-9._-]*\.\(md\|html\|sh\)' "$SKILL_MD" | sort -u)
else
  fail "SKILL.md exists"
fi

# --- expected files -------------------------------------------------------
expected_files=(
  references/mermaid-recipe.md
  templates/architecture-delta.html
  templates/architecture-map.md
  scripts/classify-diff.sh
)
for rel in "${expected_files[@]}"; do
  if [ -f "$SKILL_DIR/$rel" ]; then
    pass "expected file present: $rel"
  else
    fail "expected file present: $rel"
  fi
done

# --- template contracts --------------------------------------------------
html="$SKILL_DIR/templates/architecture-delta.html"
for ph in TITLE SUBTITLE COUNTS_HEADER COUNTS_ROW SYSTEM_MERMAID REPO_MERMAID; do
  count="$(grep -o "{{$ph}}" "$html" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" = "1" ]; then
    pass "template placeholder {{$ph}} appears once"
  else
    fail "template placeholder {{$ph}} appears once (found $count)"
  fi
done
if grep -q 'mermaid/12.2.0/mermaid.esm.min.mjs' "$html" 2>/dev/null; then
  pass "template pins mermaid 12.2.0 from cdnjs"
else
  fail "template pins mermaid 12.2.0 from cdnjs"
fi
if grep -q '^| Prefix' "$SKILL_DIR/templates/architecture-map.md" 2>/dev/null; then
  pass "map template has a Prefix table header"
else
  fail "map template has a Prefix table header"
fi
if grep -q '^classDef gebaut' "$SKILL_DIR/references/mermaid-recipe.md" 2>/dev/null; then
  pass "recipe defines the built class"
else
  fail "recipe defines the built class"
fi

# --- no local paths in shipped files ------------------------------------
leaks="$(grep -rniE '/Users/|/home/' "$SKILL_DIR" "$SCRIPT_DIR" --exclude=test-skill-structure.sh 2>/dev/null || true)"
if [ -z "$leaks" ]; then
  pass "no machine-specific paths in shipped files (skill + tests)"
else
  fail "no machine-specific paths in shipped files (skill + tests)"
  printf '%s\n' "$leaks" | head -10 | sed 's/^/    /'
fi

# --- "the user" never appears in skill prose -----------------------------
user_hits="$(grep -rn -i 'the user' "$SKILL_DIR" --include='*.md' --include='*.html' 2>/dev/null || true)"
if [ -z "$user_hits" ]; then
  pass "skill files say 'your human partner', not 'the user'"
else
  fail "skill files say 'your human partner', not 'the user'"
  printf '%s\n' "$user_hits" | head -10 | sed 's/^/    /'
fi

echo
echo "Passed: $PASSES  Failed: $FAILURES"
[ "$FAILURES" -eq 0 ]
