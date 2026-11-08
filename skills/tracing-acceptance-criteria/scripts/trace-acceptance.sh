#!/usr/bin/env bash
#
# trace-acceptance.sh — read the acceptance-criteria table of a spec and find
# every named test in the project's versioned test files.
#
# Usage: trace-acceptance.sh --spec <file> [--base <ref>]
#
# Output, TSV in table order:
#   #criterion <id> <origin> <level> <text>       one per table row
#   <id> <status> <name> <file:line|-> <hits>     one per test name
#        status: found | missing | skipped | manual (a manual row prints its
#        Tests cell as name, "-" and 0)
#   #unmapped <name> <file:line>                  with --base only: a test added
#        since <ref> in a file that holds a named test, but not in the table
#   #counts criteria=N tests=N found=N missing=N skipped=N manual=N unmapped=N
#
# Exit 0: ran. Exit 3: the spec has no marker (message on stdout).
# Exit 2: usage error, spec not found, broken table, duplicate id, not inside a
# git work tree, unknown base (message on stderr).
set -eu
set -o pipefail

usage() {
  cat >&2 <<'EOF'
Usage: trace-acceptance.sh --spec <file> [--base <ref>]
  --spec <file>  the spec holding the table behind <!-- acceptance-criteria -->
  --base <ref>   the branch this work forked from; adds tests without criterion
EOF
}

die_usage() {
  echo "error: $*" >&2
  usage
  exit 2
}

spec=""
base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spec)
      [ $# -ge 2 ] || die_usage "--spec needs a value"
      spec="$2"
      shift
      ;;
    --base)
      [ $# -ge 2 ] || die_usage "--base needs a value"
      base="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
  shift
done

[ -n "$spec" ] || die_usage "--spec <file> is required"
[ -f "$spec" ] || die_usage "spec not found: $spec"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_usage "not inside a git work tree"
if [ -n "$base" ]; then
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || die_usage "unknown ref for --base: $base"
fi
root="$(git rev-parse --show-toplevel)"

SEP="$(printf '\037')"
TAB="$(printf '\t')"
export SEP

# --- 1. the table -----------------------------------------------------------
# Records on stdout, fields separated by \037 (bash 3.2 mangles \001 in here-documents):
#   C <id> <origin> <level> <text>    T <id> <name>    M <id> <tests cell>
read_table='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function bad(msg) { printf "error: %s:%d: %s\n", spec, ln, msg > "/dev/stderr"; failed = 1; exit 2 }
function cells(s,    k, i) {
  gsub(/\\\|/, "\002", s)
  sub(/^\|/, "", s); sub(/\|[ \t]*$/, "", s)
  k = split(s, c, "|")
  for (i = 1; i <= k; i++) { gsub(/\002/, "|", c[i]); c[i] = trim(c[i]) }
  return k
}
BEGIN {
  spec = ENVIRON["TRACE_SPEC"]; sep = ENVIRON["SEP"]
  state = 0; fence = ""; marker = 0; rows = 0; ln = 0
  while ((getline line < spec) > 0) {
    ln++
    sub(/\r$/, "", line)
    if (state == 1) {
      if (line !~ /^\|/) bad("the marker must stand directly above the table header")
      if (cells(line) != 5) bad("expected 5 columns in the header, found " cells(line))
      state = 2; continue
    }
    if (state == 2) {
      if (line !~ /^\|/ || cells(line) != 5) bad("expected the separator row |---|---|---|---|---|")
      for (i = 1; i <= 5; i++) if (c[i] !~ /^:?-+:?$/) bad("expected the separator row |---|---|---|---|---|")
      state = 3; continue
    }
    if (state == 3) {
      if (line ~ /^\|/) {
        k = cells(line)
        if (k != 5) bad("expected 5 columns, found " k)
        id = c[1]; text = c[2]; origin = c[3]; level = c[4]; tests = c[5]
        if (id !~ /^[A-Z]+-[0-9]+$/) bad("invalid id \"" id "\" (letters, dash, number, e.g. AC-1)")
        if (id in seen) bad("duplicate id " id " (first at line " seen[id] ")")
        seen[id] = ln
        if (text == "") bad("empty criterion for " id)
        if (level !~ /^(API|UI|CLI|unit|manual)$/) bad("unknown level \"" level "\" for " id " (API, UI, CLI, unit, manual)")
        gsub(/\t/, " ", text); gsub(/\t/, " ", origin); gsub(/\t/, " ", tests)
        print "C" sep id sep origin sep level sep text
        rows++
        if (level == "manual") { print "M" sep id sep tests; continue }
        named = 0; rest = tests
        while (match(rest, /`[^`]+`/)) {
          name = trim(substr(rest, RSTART + 1, RLENGTH - 2))
          rest = substr(rest, RSTART + RLENGTH)
          if (name == "") continue
          print "T" sep id sep name
          named++
        }
        if (!named) bad("no test name in backticks for " id " (level " level ")")
        continue
      }
      if (!rows) bad("the table has no rows")
      state = 0
    }
    if (fence == "" && line ~ /^[ \t]*(```|~~~)/) { fence = substr(trim(line), 1, 3); continue }
    if (fence != "") { if (substr(trim(line), 1, 3) == fence) fence = ""; continue }
    if (trim(line) == "<!-- acceptance-criteria -->") {
      if (marker) bad("a second marker (the first is at line " marker ")")
      marker = ln; state = 1
    }
  }
  if (failed) exit 2
  if (state == 1 || state == 2) { ln++; bad("the marker must stand directly above the table header") }
  if (state == 3 && !rows) { ln++; bad("the table has no rows") }
  if (!marker) exit 3
}'

rc=0
records="$(TRACE_SPEC="$spec" awk "$read_table")" || rc=$?
if [ "$rc" -eq 3 ]; then
  echo "no acceptance criteria in $spec"
  exit 3
fi
[ "$rc" -eq 0 ] || exit 2

# --- 2. the search ----------------------------------------------------------
# For one name: every hit in a versioned test file (a path token is test(s),
# spec(s) or e2e, or carries a Test/Spec word; Markdown and .tasks.json never
# count). Prints
#   <file>\037<line>\037<hits>\037<skipped 0|1>      ("-", "-", 0, 0 when none)
# and appends every file with a hit to $hit_files.
pick_hits='
function is_test(p,    lp, k, i, t) {
  lp = tolower(p)
  if (lp ~ /\.(md|markdown)$/ || lp ~ /\.tasks\.json$/) return 0
  k = split(p, tok, "[^A-Za-z0-9]+")
  for (i = 1; i <= k; i++) {
    t = tok[i]
    if (tolower(t) ~ /^(tests?|specs?|e2e)$/) return 1
    if (t ~ /[a-z0-9](Tests?|Specs?)$/) return 1
    if (t ~ /^(Tests?|Specs?)[A-Z0-9]/) return 1
  }
  return 0
}
function marker(s) {
  return index(s, ".skip(") || index(s, ".todo(") || index(s, "@skip") ||
         index(s, "@Disabled") || index(s, "@Ignore") || index(s, "pytest.mark.skip") ||
         index(s, "#[ignore]") || index(s, "markTestSkipped") || index(s, "t.Skip(") ||
         s ~ /(^|[^A-Za-z0-9_$.])x(it|test)\(/
}
function body_marker(s) { return index(s, "markTestSkipped") || index(s, "t.Skip(") }
BEGIN { FS = ENVIRON["SEP"]; sep = FS; root = ENVIRON["TRACE_ROOT"]; files = ENVIRON["TRACE_HIT_FILES"] }
is_test($1) {
  hits++
  if (first == "") { first = $1; at = $2 + 0 }
  if (!($1 in listed)) { listed[$1] = 1; print $1 >> files }
}
END {
  if (first == "") { print "-" sep "-" sep 0 sep 0; exit }
  path = root "/" first; n = 0; above = ""; hit = ""; b1 = ""; b2 = ""
  while ((getline l < path) > 0) {
    n++
    if (n == at - 1) above = l
    else if (n == at) hit = l
    else if (n == at + 1) b1 = l
    else if (n == at + 2) { b2 = l; break }
  }
  close(path)
  skipped = (marker(above) || marker(hit) || body_marker(b1) || body_marker(b2)) ? 1 : 0
  print first sep at sep hits sep skipped
}'

hit_files="$(mktemp)"
trap 'rm -f "$hit_files"' EXIT

# An identifier (itRedirectsToStart, test_login) matches as a whole word; any
# other name is a string-named test and matches only inside quotes, so
# 'logs in' never matches 'logs in twice'.
search() {
  local pattern
  case "$1" in
    *[!A-Za-z0-9_]*) pattern=(-F -e "'$1'" -e "\"$1\"" -e "\`$1\`") ;;
    *) pattern=(-w -F -e "$1") ;;
  esac
  { git -C "$root" -c core.quotePath=false grep -n -z "${pattern[@]}" 2>/dev/null || true; } \
    | tr '\000' '\037' \
    | TRACE_ROOT="$root" TRACE_HIT_FILES="$hit_files" awk "$pick_hits"
}

criteria=0
found=0
missing=0
skipped=0
manual=0
names="$SEP"
out=""
while IFS="$SEP" read -r kind id f2 f3 f4; do
  case "$kind" in
    C)
      criteria=$((criteria + 1))
      out="$out#criterion$TAB$id$TAB$f2$TAB$f3$TAB$f4
"
      ;;
    M)
      manual=$((manual + 1))
      out="$out$id${TAB}manual$TAB$f2$TAB-${TAB}0
"
      ;;
    T)
      names="$names$f2$SEP"
      IFS="$SEP" read -r file line hits skip <<EOF
$(search "$f2")
EOF
      if [ "$file" = "-" ]; then
        status=missing
        missing=$((missing + 1))
        where="-"
      else
        where="$file:$line"
        if [ "$skip" = 1 ]; then
          status=skipped
          skipped=$((skipped + 1))
        else
          status=found
          found=$((found + 1))
        fi
      fi
      out="$out$id$TAB$status$TAB$f2$TAB$where$TAB$hits
"
      ;;
  esac
done <<EOF
$records
EOF
printf '%s' "$out"

# --- 3. tests without criterion (--base only) --------------------------------
# Added lines since <base> in every file with a hit; a line that declares a
# test whose name is not in the table is reported.
find_declared='
BEGIN { sep = ENVIRON["SEP"]; file = ENVIRON["TRACE_FILE"]; names = ENVIRON["TRACE_NAMES"]; q = sprintf("%c", 39) }
/^@@/ { s = $0; sub(/^@@ -[0-9,]+ \+/, "", s); split(s, a, /[ ,]/); ln = a[1] + 0; next }
/^\+\+\+ / || /^--- / { next }
/^\+/ {
  l = substr($0, 2); name = ""
  if (match(l, "(^|[^A-Za-z0-9_$.])x?(it|test)(\\.(only|skip|todo))?\\([ \t]*[\"`" q "]")) {
    rest = substr(l, RSTART + RLENGTH); quote = substr(l, RSTART + RLENGTH - 1, 1)
    end = index(rest, quote)
    if (end > 1) name = substr(rest, 1, end - 1)
  } else if (match(l, /(^|[^A-Za-z0-9_])(function|def|func|fun|void|fn)[ \t]+(it[A-Z][A-Za-z0-9_]*|test[A-Za-z0-9_]*|Test[A-Za-z0-9_]*)/)) {
    m = substr(l, RSTART, RLENGTH); sub(/^.*[ \t]/, "", m); name = m
  } else if (match(l, /^[ \t]*it[A-Z][A-Za-z0-9_]*[ \t]*\(\)/)) {
    m = substr(l, RSTART, RLENGTH); sub(/^[ \t]+/, "", m); sub(/[ \t]*\(\)$/, "", m); name = m
  }
  if (name != "" && index(names, sep name sep) == 0) print name "\t" file ":" ln
  ln++
  next
}'

unmapped=0
if [ -n "$base" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      printf '#unmapped\t%s\n' "$row"
      unmapped=$((unmapped + 1))
    done <<EOF
$(git -C "$root" -c core.quotePath=false diff -U0 --no-color --no-ext-diff "${base}...HEAD" -- "$file" \
      | TRACE_FILE="$file" TRACE_NAMES="$names" awk "$find_declared")
EOF
  done <<EOF
$(awk '!seen[$0]++' "$hit_files")
EOF
fi

tests=$((found + missing + skipped + manual))
printf '#counts\tcriteria=%d\ttests=%d\tfound=%d\tmissing=%d\tskipped=%d\tmanual=%d\tunmapped=%d\n' \
  "$criteria" "$tests" "$found" "$missing" "$skipped" "$manual" "$unmapped"
