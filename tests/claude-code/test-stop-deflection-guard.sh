#!/usr/bin/env bash
# Test: stop-deflection-guard.sh on synthetic transcripts. Deterministic, no LLM.
# Covers the sanctioned session-handoff exemption and the phrase block it must
# not weaken.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/examples/stop-deflection-guard.sh"
WORK=$(mktemp -d)
FAILED=0
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

echo "=== Test: stop-deflection-guard ==="
echo ""

# mk_text NAME TEXT -> transcript whose last assistant text is TEXT at low context
mk_text() {
    python3 -c '
import json, sys
text = sys.argv[1]
entry = {"type": "assistant", "message": {"content": [{"type": "text", "text": text}],
         "usage": {"input_tokens": 1000, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}}
print(json.dumps(entry))
' "$2" > "$WORK/$1.jsonl"
}

run_hook() { # $1=transcript [$2...=env assignments]
    local path="$1"; shift
    printf '{"session_id":"s","transcript_path":"%s","stop_hook_active":false}' "$path" \
        | env HOME="$WORK/home" SUPERPOWERS_CONTEXT_LIMIT=200000 SUPERPOWERS_DEFLECTION_THRESHOLD_PCT=50 "$@" \
            bash "$HOOK" 2>"$WORK/stderr"
    echo "$?"
}

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label — expected exit=$expected, got exit=$actual"
        echo "         stderr: $(head -2 "$WORK/stderr" | tr '\n' ' ')"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    if grep -qF "$2" "$WORK/stderr"; then
        echo "  [PASS] $1"
    else
        echo "  [FAIL] $1 — stderr missing: $2"
        FAILED=$((FAILED + 1))
    fi
}

mkdir -p "$WORK/home"
FENCE='```'

mk_text handoff-en "The plan is saved at docs/plans/x.md.

Changes? Tell me here and I'll show this block again. Otherwise, starting the next session is your go.

/clear, then:

${FENCE}
/superpowers:executing-plans docs/plans/x.md
${FENCE}"
mk_text handoff-de "Der Plan liegt unter docs/plans/x.md.

Aenderungen? Sag es hier, dann zeige ich den Block erneut. Sonst ist der Start der naechsten Session dein Go.

  /clear, then:

${FENCE}
/superpowers:executing-plans docs/plans/x.md
${FENCE}"
mk_text excuse "Let's pick this up in the next session."
mk_text quoted "To continue, type /clear, then: the command, in the next session."

echo "Test 1: English handoff block, low context → allow"
assert "exit code" "0" "$(run_hook "$WORK/handoff-en.jsonl")"
echo ""

echo "Test 2: plain deferral without the line → block"
assert "exit code" "2" "$(run_hook "$WORK/excuse.jsonl")"
assert_stderr_contains "names the phrase" "next session"
echo ""

echo "Test 3: German handoff block → allow"
assert "exit code" "0" "$(run_hook "$WORK/handoff-de.jsonl")"
echo ""

echo "Test 4: '/clear, then:' only quoted in prose → block"
assert "exit code" "2" "$(run_hook "$WORK/quoted.jsonl")"
echo ""

echo "Test 5: kill switch → allow"
assert "exit code" "0" "$(run_hook "$WORK/excuse.jsonl" SUPERPOWERS_DEFLECTION_GUARD=0)"
echo ""

echo "=== Summary: $FAILED failure(s) ==="
exit "$FAILED"
