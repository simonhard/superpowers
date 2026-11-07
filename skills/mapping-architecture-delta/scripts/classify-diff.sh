#!/usr/bin/env bash
#
# classify-diff.sh — turn `git diff --name-status` into one row per file with
# its status, its block and its zone, resolved through the project's
# architecture map (docs/superpowers/architecture-map.md) by longest prefix.
#
# Output: TSV rows "<status>\t<path>\t<block>\t<zone>" sorted by path, then
#   #counts\tadded=N\tmodified=N\tdeleted=N\trenamed=N\tunmapped=N
#   #unmapped\t<path>        (one per unmapped path; absent when none)
# Status: A new, M modified, D deleted, R renamed (path shown as "old -> new").
# Unmapped paths carry block "?" and zone "-".
# Exit 2 on a missing --base, an unknown ref, a missing explicit --map, or
# outside a git work tree.
set -eu
set -o pipefail

usage() {
  cat >&2 <<'EOF'
Usage: classify-diff.sh --base <ref> [--head <ref>] [--map <file>]
  --base <ref>   the ref this branch forked from (required)
  --head <ref>   the ref to compare against (default: HEAD)
  --map <file>   architecture map (default: docs/superpowers/architecture-map.md when present)
EOF
}

die_usage() {
  echo "error: $*" >&2
  usage
  exit 2
}

base_ref=""
head_ref="HEAD"
map_file=""
map_explicit=false

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      [ $# -ge 2 ] || die_usage "--base needs a value"
      base_ref="$2"
      shift
      ;;
    --head)
      [ $# -ge 2 ] || die_usage "--head needs a value"
      head_ref="$2"
      shift
      ;;
    --map)
      [ $# -ge 2 ] || die_usage "--map needs a value"
      map_file="$2"
      map_explicit=true
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

[ -n "$base_ref" ] || die_usage "--base <ref> is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die_usage "not inside a git work tree"
git rev-parse --verify --quiet "${base_ref}^{commit}" >/dev/null || die_usage "unknown ref for --base: $base_ref"
git rev-parse --verify --quiet "${head_ref}^{commit}" >/dev/null || die_usage "unknown ref for --head: $head_ref"

if [ "$map_explicit" = true ]; then
  [ -f "$map_file" ] || die_usage "map file not found: $map_file"
else
  repo_root="$(git rev-parse --show-toplevel)"
  if [ -f "$repo_root/docs/superpowers/architecture-map.md" ]; then
    map_file="$repo_root/docs/superpowers/architecture-map.md"
  fi
fi

tab="$(printf '\t')"

git -c core.quotePath=false diff --name-status -M "${base_ref}...${head_ref}" \
  | LC_ALL=C sort -t "$tab" -k2,2 \
  | awk -F '\t' -v map="$map_file" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function lookup(path,    i, best, bestlen) {
      best = 0; bestlen = -1
      for (i = 1; i <= n; i++)
        if (length(pre[i]) > bestlen && substr(path, 1, length(pre[i])) == pre[i]) {
          best = i; bestlen = length(pre[i])
        }
      return best
    }
    BEGIN {
      n = 0; inmap = 0
      added = 0; modified = 0; deleted = 0; renamed = 0; unmapped = 0; u = 0
      if (map != "") {
        while ((getline line < map) > 0) {
          sub(/\r$/, "", line)
          if (line !~ /^[ \t]*\|/) continue
          sub(/^[ \t]*\|/, "", line); sub(/\|[ \t]*$/, "", line)
          k = split(line, c, "|")
          for (i = 1; i <= k; i++) c[i] = trim(c[i])
          if (c[1] == "Prefix") { inmap = 1; continue }
          if (c[1] == "From") { inmap = 0; continue }
          if (!inmap || c[1] == "" || c[1] ~ /^:?-+:?$/) continue
          n++; pre[n] = c[1]; blk[n] = c[2]
          zone[n] = (k >= 3) ? c[3] : ""
          if (zone[n] == "" || zone[n] == "\342\200\224") zone[n] = "-"
        }
        close(map)
      }
    }
    {
      code = substr($1, 1, 1)
      if (code == "R")      { shown = $2 " -> " $3; key = $3; renamed++ }
      else if (code == "A") { shown = $2; key = $2; added++ }
      else if (code == "D") { shown = $2; key = $2; deleted++ }
      else if (code == "C") { shown = $3; key = $3; code = "A"; added++ }
      else                  { shown = $2; key = $2; code = "M"; modified++ }
      m = lookup(key)
      if (m) { b = blk[m]; z = zone[m] }
      else   { b = "?"; z = "-"; unmapped++; u++; un[u] = key }
      printf "%s\t%s\t%s\t%s\n", code, shown, b, z
    }
    END {
      printf "#counts\tadded=%d\tmodified=%d\tdeleted=%d\trenamed=%d\tunmapped=%d\n", added, modified, deleted, renamed, unmapped
      for (i = 1; i <= u; i++) printf "#unmapped\t%s\n", un[i]
    }'
