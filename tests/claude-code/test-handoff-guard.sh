#!/usr/bin/env bash
# Test: pre-askuser-handoff-guard hook — synthetic transcripts, no LLM.
# Covers all decision branches: armed via Skill tool_use, armed via user-message
# invocation (content as string AND as text-block list), any question after the
# plan → block with the handoff block (the retired three-option menu included),
# CLARIFICATION token → allow, disarmed by later execution Skill → allow, no
# TaskCreate after arm → allow, no routing file → allow, kill switch → allow,
# non-AskUserQuestion tool → allow, missing/garbage transcript → allow, and the
# command the block names per routing file (parallelSession).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/pre-askuser-handoff-guard"
WORK=$(mktemp -d)
export SUPERPOWERS_USERGATE_TRACE_LOG="$WORK/trace.log"
FAILED=0
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

echo "=== Test: pre-askuser-handoff-guard ==="
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label — expected exit=$expected, got exit=$actual"
        echo "         stderr: $(head -3 "$WORK/stderr" 2>/dev/null | tr '\n' ' ')"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    local label="$1" needle="$2"
    if grep -qF "$needle" "$WORK/stderr" 2>/dev/null; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label — stderr missing: $needle"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_lacks() {
    local label="$1" needle="$2"
    if grep -qF -- "$needle" "$WORK/stderr" 2>/dev/null; then
        echo "  [FAIL] $label — stderr contains: $needle"
        FAILED=$((FAILED + 1))
    else
        echo "  [PASS] $label"
    fi
}

run_hook() {
    # Usage: run_hook <json-input> [env-overrides...]
    # Runs hook, discards stdout (ALLOW JSON), captures stderr.
    # Prints exit code on stdout.
    # HOME is isolated so a real ~/.claude/superpowers/model-routing.json
    # can't pollute "no routing file" tests.
    local input="$1" _rc; shift
    env HOME="$ISOLATED_HOME" "$@" bash "$HOOK" >/dev/null 2>"$WORK/stderr" <<< "$input" && _rc=$? || _rc=$?
    echo "$_rc"
}
ISOLATED_HOME="$WORK/isolated-home"
mkdir -p "$ISOLATED_HOME"

# Routing file used by most tests (presence triggers the guard).
ROUTING_DIR="$WORK/project/docs/superpowers"
mkdir -p "$ROUTING_DIR"
cat > "$ROUTING_DIR/model-routing.json" <<'EOF'
{"mechanical":"haiku","standard":"sonnet","frontier":"inherit"}
EOF

# ---------------------------------------------------------------------------
# Transcripts
# ---------------------------------------------------------------------------

# Transcript: writing-plans invoked via Skill tool_use + TaskCreate after.
cat > "$WORK/armed-via-skill.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1","description":"**Goal:** do thing\n```json:metadata\n{\"modelTier\":\"mechanical\"}\n```"}}]}}
EOF

# Transcript: writing-plans invoked via user message (slash command injection) — content as string.
# Real Claude Code slash-command invocations inject a <command-name> tag; this
# is the failure mode the gate exists to catch (genuine invocation, not a mention).
cat > "$WORK/armed-via-user-string.jsonl" <<'EOF'
{"type":"user","message":{"content":"<command-message>writing-plans</command-message><command-name>/superpowers-extended-cc:writing-plans</command-name>"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1","description":"**Goal:** do thing\n```json:metadata\n{\"modelTier\":\"mechanical\"}\n```"}}]}}
EOF

# Transcript: writing-plans invoked via user message — content as text-block list.
# Path passed as argv (not embedded in the source): MSYS path conversion on
# Windows rewrites argv only, so an inline '$WORK/...' string is unopenable
# for native Windows Python.
python3 -c "
import json, sys
lines = [
    {\"type\": \"user\", \"message\": {\"content\": [{\"type\": \"text\", \"text\": \"<command-message>writing-plans</command-message><command-name>/superpowers-extended-cc:writing-plans</command-name>\"}]}},
    {\"type\": \"assistant\", \"message\": {\"content\": [{\"type\": \"tool_use\", \"name\": \"TaskCreate\", \"input\": {\"subject\": \"Task 1\", \"description\": \"Goal: do thing\"}}]}}
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/armed-via-user-blocks.jsonl"

# Transcript: armed, then disarmed by later subagent-driven-development Skill invocation.
cat > "$WORK/disarmed-by-execution.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1","description":"goal"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:subagent-driven-development"}}]}}
EOF

# Transcript: writing-plans arm but no TaskCreate after it.
cat > "$WORK/arm-no-taskcreate.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
EOF

# No writing-plans signal at all.
cat > "$WORK/no-arm.jsonl" <<'EOF'
{"type":"user","message":{"content":"Hello"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Unrelated task","description":"goal"}}]}}
EOF

# Garbage transcript.
cat > "$WORK/garbage.jsonl" <<'EOF'
this is not json at all
{also bad}
EOF

# Empty transcript.
: > "$WORK/empty.jsonl"

# ---------------------------------------------------------------------------
# AskUserQuestion inputs
# ---------------------------------------------------------------------------

# The retired three-option execution menu. It used to be the mandated handoff;
# now it asks for a go the next session gives, so it blocks like any question.
make_old_menu_input() {
    local transcript="$1" cwd="${2:-$WORK/project}"
    python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {
        'questions': [{
            'question': 'Plan complete and saved to docs/superpowers/plans/2026-06-10-foo.md. How would you like to execute it?',
            'header': 'Execution',
            'options': [
                {'label': 'Subagent-Driven (this session)', 'description': 'Runs here: fresh subagent per task.'},
                {'label': 'Parallel Session (separate)', 'description': 'You open a second session that runs subagent-driven-development.'},
                {'label': 'Parallel Session, inline (separate)', 'description': 'You open a second session that implements every task itself.'}
            ]
        }]
    },
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$transcript" "$cwd"
}

# Wrong options (improvised custom menu — the pattern this gate catches).
make_wrong_options_input() {
    local transcript="$1" cwd="${2:-$WORK/project}"
    python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {
        'questions': [{
            'question': 'How would you like to proceed?',
            'header': 'Execution Plan',
            'options': [
                {'label': 'Phase 1: Foundation (Tasks 1-5)', 'description': 'Start with core'},
                {'label': 'Phase 2: Integration (Tasks 6-12)', 'description': 'After phase 1'},
                {'label': 'Phase 3: Polish (Tasks 13-19)', 'description': 'Final phase'},
                {'label': 'All phases sequentially', 'description': 'Run everything'}
            ]
        }]
    },
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$transcript" "$cwd"
}

# CLARIFICATION token in question.
make_clarification_input() {
    local transcript="$1" cwd="${2:-$WORK/project}"
    python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {
        'questions': [{
            'question': 'CLARIFICATION: Should the database migrations run before or after seeding?',
            'header': 'Migration order',
            'options': [
                {'label': 'Before seeding'},
                {'label': 'After seeding'}
            ]
        }]
    },
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$transcript" "$cwd"
}

# Non-AskUserQuestion tool.
make_bash_input() {
    local transcript="$1" cwd="${2:-$WORK/project}"
    python3 -c "
import json, sys
inp = {
    'tool_name': 'Bash',
    'tool_input': {'command': 'ls'},
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$transcript" "$cwd"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "Test 1: no routing file → allow (dormant)"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$WORK")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 2: kill switch SUPERPOWERS_ROUTING_GUARD=0 → allow"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
rc=$(run_hook "$INPUT" SUPERPOWERS_ROUTING_GUARD=0)
assert "exit code" "0" "$rc"
echo ""

echo "Test 3: non-AskUserQuestion tool → allow"
INPUT=$(make_bash_input "$WORK/armed-via-skill.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 4: missing transcript → allow (fail-open)"
INPUT=$(python3 -c "
import json
print(json.dumps({'tool_name': 'AskUserQuestion', 'tool_input': {'questions': [{'question': 'x', 'options': [{'label': 'a'}]}]}, 'transcript_path': '/tmp/nonexistent-transcript-xyz.jsonl', 'cwd': '$WORK/project'}))
")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 5: garbage transcript → allow (fail-open)"
INPUT=$(make_wrong_options_input "$WORK/garbage.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 6: no writing-plans signal → allow (not armed)"
INPUT=$(make_wrong_options_input "$WORK/no-arm.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 7: writing-plans arm but no TaskCreate after it → allow (not armed)"
INPUT=$(make_wrong_options_input "$WORK/arm-no-taskcreate.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 8: armed via Skill tool_use + wrong options → BLOCK"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
assert_stderr_contains "headline present" "EXECUTION HANDOFF: no AskUserQuestion after the plan is written."
assert_stderr_contains "footer trace log" "Trace log:"
assert_stderr_contains "footer rationale" "docs/model-routing-flow.md"
echo ""

echo "Test 9: armed via Skill tool_use + retired three-option menu → BLOCK"
INPUT=$(make_old_menu_input "$WORK/armed-via-skill.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
echo ""

echo "Test 10: armed via user-message string + wrong options → BLOCK"
INPUT=$(make_wrong_options_input "$WORK/armed-via-user-string.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
assert_stderr_contains "headline" "EXECUTION HANDOFF: no AskUserQuestion after the plan is written."
echo ""

echo "Test 11: armed via user-message string + retired three-option menu → BLOCK"
INPUT=$(make_old_menu_input "$WORK/armed-via-user-string.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
echo ""

echo "Test 12: armed via user-message text-block list + wrong options → BLOCK"
INPUT=$(make_wrong_options_input "$WORK/armed-via-user-blocks.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
assert_stderr_contains "headline (text-block path)" "EXECUTION HANDOFF: no AskUserQuestion after the plan is written."
echo ""

echo "Test 13: armed via user-message text-block list + retired three-option menu → BLOCK"
INPUT=$(make_old_menu_input "$WORK/armed-via-user-blocks.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "2" "$rc"
echo ""

echo "Test 14: disarmed by later execution Skill invocation → allow"
INPUT=$(make_wrong_options_input "$WORK/disarmed-by-execution.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 16: armed + CLARIFICATION token in question → allow (clarification escape)"
INPUT=$(make_clarification_input "$WORK/armed-via-skill.jsonl")
rc=$(run_hook "$INPUT")
assert "exit code" "0" "$rc"
echo ""

echo "Test 17: block message is the handoff block"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
run_hook "$INPUT" >/dev/null || true
assert_stderr_contains "plan line" "Plan written to <plan path>."
assert_stderr_contains "changes sentence" "Changes? Tell me here and I'll show this block again. Otherwise, starting the next session is your go."
assert_stderr_contains "clear line" "/clear, then:"
assert_stderr_contains "command line" "/superpowers-extended-cc:subagent-driven-development <absolute plan path>"
assert_stderr_contains "nothing after the block" "Nothing after the code block. Name no model."
assert_stderr_contains "clarification escape" "CLARIFICATION"
assert_stderr_contains "kill switch" "SUPERPOWERS_ROUTING_GUARD=0"
echo ""

echo "Test 18: user-level routing file (no project file) → active"
FAKEHOME="$WORK/fakehome"
mkdir -p "$FAKEHOME/.claude/superpowers"
cp "$ROUTING_DIR/model-routing.json" "$FAKEHOME/.claude/superpowers/model-routing.json"
NOPROJ="$WORK/noproject"
mkdir -p "$NOPROJ"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$NOPROJ")
rc=$(run_hook "$INPUT" HOME="$FAKEHOME")
assert "violation blocks via user-level file" "2" "$rc"
rc=$(run_hook "$INPUT" HOME="$WORK")  # HOME with no .claude dir → dormant
assert "dormant when neither file exists" "0" "$rc"
echo ""

echo "Test 19: re-arm for a second plan — stale TaskCreate from plan 1 must NOT arm"
# Live false-block: plan 1 completes (arm → TaskCreate → compliant handoff),
# then writing-plans is re-invoked for a second plan. Before the second plan
# creates any tasks, a clarifying AskUserQuestion is legitimate — the
# TaskCreate from plan 1 must not count as "tasks created after arm".
cat > "$WORK/rearm-second-plan.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1","description":"goal"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Plan complete. How would you like to execute it?","options":[{"label":"Subagent-Driven (this session)"},{"label":"Parallel Session (separate)"}]}]}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
EOF
INPUT=$(make_wrong_options_input "$WORK/rearm-second-plan.jsonl")
rc=$(run_hook "$INPUT")
assert "clarifying question in second plan cycle → allow" "0" "$rc"
# Once the second plan creates a task, the guard must arm again.
cat "$WORK/rearm-second-plan.jsonl" > "$WORK/rearm-with-taskcreate.jsonl"
cat >> "$WORK/rearm-with-taskcreate.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1 of plan 2","description":"goal"}}]}}
EOF
INPUT=$(make_wrong_options_input "$WORK/rearm-with-taskcreate.jsonl")
rc=$(run_hook "$INPUT")
assert "wrong menu after second plan's TaskCreate → block" "2" "$rc"
echo ""

echo "Test 20: invalid-UTF-8 byte in transcript poisons only its own line"
# Regression: text-mode readlines() threw UnicodeDecodeError for the WHOLE
# file on one bad byte, silently disarming the guard for the session.
{ printf '\x80 corrupt line\n'; cat "$WORK/armed-via-skill.jsonl"; } > "$WORK/badutf8-armed.jsonl"
INPUT=$(make_wrong_options_input "$WORK/badutf8-armed.jsonl")
rc=$(run_hook "$INPUT")
assert "armed transcript with bad byte + wrong options → still block" "2" "$rc"
INPUT=$(make_old_menu_input "$WORK/badutf8-armed.jsonl")
rc=$(run_hook "$INPUT")
assert "armed transcript with bad byte + retired menu → block" "2" "$rc"
echo ""

echo "Test 21: /bin/bash canary — block path must work on stock macOS bash 3.2"
# Claude Code invokes hooks through run-hook.cmd (exec bash), which on a
# stock Mac is 3.2 — where e.g. an IFS of \\x01 silently fails to split (CTLESC).
# One block scenario under /bin/bash catches any always-allow regression there.
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
_rc=0
env HOME="$ISOLATED_HOME" /bin/bash "$HOOK" >/dev/null 2>"$WORK/stderr" <<< "$INPUT" && _rc=$? || _rc=$?
assert "armed wrong-menu blocks under /bin/bash" "2" "$_rc"
echo ""

echo "Test 23: skill-body injection after arm must NOT disarm"
# Live miss (2026-09-12): invoking writing-plans injects its body as a user
# message beginning "Base directory for this skill:"; that body names
# executing-plans in its handoff section, which the scan took as a disarm
# signal one line after the arm. The guard then slept through the real handoff.
python3 -c "
import json, sys
body = 'Base directory for this skill: /x/skills/writing-plans\n\n## Execution Handoff\nInvoke the Skill tool: superpowers-extended-cc:subagent-driven-development ... Invoke superpowers-extended-cc:executing-plans for the plan path.'
lines = [
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'Skill', 'input': {'skill': 'superpowers-extended-cc:writing-plans'}}]}},
    {'type': 'user', 'message': {'content': [{'type': 'text', 'text': body}]}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/skill-body-after-arm.jsonl"
INPUT=$(make_wrong_options_input "$WORK/skill-body-after-arm.jsonl")
rc=$(run_hook "$INPUT")
assert "skill body mention does not disarm → wrong menu blocks" "2" "$rc"
# A human instruction that merely NAMES the execution skill late in a long
# message (free text, no <command-name> tag) is a mention, not an invocation,
# and must NOT disarm on its own - user-message arm/disarm only fires on a
# genuine slash-command <command-name> tag. If the model actually acts on the
# instruction it calls the Skill tool, which arms/disarms via tool_use as before.
python3 -c "
import json, sys
doc = 'Some context about the plan first. ' * 12 + 'Now run superpowers-extended-cc:executing-plans on it instead.'
lines = [
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'Skill', 'input': {'skill': 'superpowers-extended-cc:writing-plans'}}]}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
    {'type': 'user', 'message': {'content': doc}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/late-human-invocation.jsonl"
INPUT=$(make_wrong_options_input "$WORK/late-human-invocation.jsonl")
rc=$(run_hook "$INPUT")
assert "mention of execution skill in free text does not disarm → still blocked" "2" "$rc"
# A real invocation at the head of a user message still disarms.
INPUT=$(make_wrong_options_input "$WORK/disarmed-by-execution.jsonl")
rc=$(run_hook "$INPUT")
assert "execution Skill invocation still disarms → allow" "0" "$rc"
echo ""

echo "Test 26: user message that only MENTIONS writing-plans (no command-name tag) must NOT arm"
# A slash command's injected body may mention a skill by name without invoking
# it; a mention is not an invocation and must not arm the guard.
python3 -c "
import json, sys
body = 'Stub command body. Next step: /superpowers-extended-cc:writing-plans'
lines = [
    {'type': 'user', 'message': {'content': body}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Stub task', 'description': 'goal'}}]}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/mention-only-no-arm.jsonl"
INPUT=$(python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {'questions': [{'question': 'Stub question?', 'header': 'Stub', 'options': [{'label': 'Stub A'}, {'label': 'Stub B'}]}]},
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$WORK/mention-only-no-arm.jsonl" "$WORK/project")
rc=$(run_hook "$INPUT")
assert "mention-only body does not arm → unrelated question allowed" "0" "$rc"
echo ""

echo "Test 27: user message that only MENTIONS an execution skill must NOT disarm a real arm"
# Same rule in reverse: a genuinely armed guard must stay armed even if a
# later user message body merely mentions an execution skill in passing.
python3 -c "
import json, sys
mention = 'Stub note mentioning /superpowers-extended-cc:executing-plans and subagent-driven-development in passing, unrelated to this exchange.'
lines = [
    {'type': 'user', 'message': {'content': '<command-message>writing-plans</command-message><command-name>/superpowers-extended-cc:writing-plans</command-name>'}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
    {'type': 'user', 'message': {'content': mention}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/mention-only-no-disarm.jsonl"
INPUT=$(make_wrong_options_input "$WORK/mention-only-no-disarm.jsonl")
rc=$(run_hook "$INPUT")
assert "mention-only body does not disarm → armed guard still blocks wrong menu" "2" "$rc"
echo ""

echo "Test 28: genuine command-name tag invocation still arms and blocks a non-handoff question"
python3 -c "
import json, sys
lines = [
    {'type': 'user', 'message': {'content': '<command-message>writing-plans</command-message><command-name>/superpowers-extended-cc:writing-plans</command-name>'}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/genuine-command-tag-arm.jsonl"
INPUT=$(python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {'questions': [{'question': 'Stub question?', 'header': 'Stub', 'options': [{'label': 'Stub A'}, {'label': 'Stub B'}]}]},
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$WORK/genuine-command-tag-arm.jsonl" "$WORK/project")
rc=$(run_hook "$INPUT")
assert "genuine command-name tag invocation arms → non-handoff question blocked" "2" "$rc"
echo ""

echo "Test 29: a user message that QUOTES the command-name tag in prose must NOT arm"
python3 -c "
import json, sys
body = 'The hook checks <command-name>/superpowers-extended-cc:writing-plans</command-name>, just explaining.'
lines = [
    {'type': 'user', 'message': {'content': body}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Stub task', 'description': 'goal'}}]}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/quoted-tag-no-arm.jsonl"
INPUT=$(python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {'questions': [{'question': 'Stub question?', 'header': 'Stub', 'options': [{'label': 'Stub A'}, {'label': 'Stub B'}]}]},
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$WORK/quoted-tag-no-arm.jsonl" "$WORK/project")
rc=$(run_hook "$INPUT")
assert "quoted tag in prose does not arm → unrelated question allowed" "0" "$rc"
echo ""

echo "Test 30: a user message that QUOTES an execution-skill command-name tag in prose must NOT disarm"
python3 -c "
import json, sys
mention = 'Explaining the format: it looks like <command-name>/superpowers-extended-cc:executing-plans</command-name> in the transcript.'
lines = [
    {'type': 'user', 'message': {'content': '<command-message>writing-plans</command-message><command-name>/superpowers-extended-cc:writing-plans</command-name>'}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
    {'type': 'user', 'message': {'content': mention}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/quoted-tag-no-disarm.jsonl"
INPUT=$(make_wrong_options_input "$WORK/quoted-tag-no-disarm.jsonl")
rc=$(run_hook "$INPUT")
assert "quoted execution-skill tag in prose does not disarm → armed guard still blocks wrong menu" "2" "$rc"
echo ""

echo "Test 31: the real command-message/command-name/command-args invocation format still arms"
python3 -c "
import json, sys
lines = [
    {'type': 'user', 'message': {'content': '<command-message>writing-plans</command-message>\n<command-name>/superpowers-extended-cc:writing-plans</command-name>\n<command-args>docs/plans/stub.md</command-args>'}},
    {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'name': 'TaskCreate', 'input': {'subject': 'Task 1', 'description': 'goal'}}]}},
]
with open(sys.argv[1], 'w') as f:
    for l in lines:
        f.write(json.dumps(l) + '\n')
" "$WORK/real-format-with-args-arm.jsonl"
INPUT=$(python3 -c "
import json, sys
inp = {
    'tool_name': 'AskUserQuestion',
    'tool_input': {'questions': [{'question': 'Stub question?', 'header': 'Stub', 'options': [{'label': 'Stub A'}, {'label': 'Stub B'}]}]},
    'transcript_path': sys.argv[1],
    'cwd': sys.argv[2]
}
print(json.dumps(inp))
" "$WORK/real-format-with-args-arm.jsonl" "$WORK/project")
rc=$(run_hook "$INPUT")
assert "real command-message/command-name/command-args format arms → non-handoff question blocked" "2" "$rc"
echo ""

echo "Test 32: block message carries no AskUserQuestion YAML"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
run_hook "$INPUT" >/dev/null || true
assert_stderr_lacks "no AskUserQuestion YAML" "AskUserQuestion:"
echo ""

echo "Test 33: block message drops the retired menu labels"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
run_hook "$INPUT" >/dev/null || true
assert_stderr_lacks "no 'Subagent-Driven (this session)'" "Subagent-Driven (this session)"
echo ""

echo "Test 35: block message offers no parallel session"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl")
run_hook "$INPUT" >/dev/null || true
assert_stderr_lacks "no 'Parallel Session'" "Parallel Session"
echo ""

# ---------------------------------------------------------------------------
# parallelSession: which execution command the block names
# ---------------------------------------------------------------------------

make_routing_project() { # $1=dir name under $WORK  $2=file content
    mkdir -p "$WORK/$1/docs/superpowers"
    printf '%s\n' "$2" > "$WORK/$1/docs/superpowers/model-routing.json"
}
make_routing_project project-parallel-exec '{"mechanical":"haiku","standard":"sonnet","frontier":"inherit","parallelSession":"executing-plans"}'
make_routing_project project-parallel-sdd '{"mechanical":"haiku","standard":"sonnet","frontier":"inherit","parallelSession":"subagent-driven-development"}'
make_routing_project project-parallel-unknown '{"mechanical":"haiku","standard":"sonnet","frontier":"inherit","parallelSession":"turbo"}'
make_routing_project project-broken-json '{"mechanical": "haiku", "parallelSession": '

CMD_SDD="/superpowers-extended-cc:subagent-driven-development <absolute plan path>"
CMD_EXEC="/superpowers-extended-cc:executing-plans <absolute plan path>"

echo "Test 41: the routing file picks the command the block names"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$WORK/project-parallel-exec")
rc=$(run_hook "$INPUT")
assert "parallelSession=executing-plans → block" "2" "$rc"
assert_stderr_contains "names executing-plans" "$CMD_EXEC"
assert_stderr_lacks "does not name subagent-driven-development" "$CMD_SDD"
for proj in project-parallel-sdd project-parallel-unknown project-broken-json project; do
    INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$WORK/$proj")
    rc=$(run_hook "$INPUT")
    assert "$proj → block" "2" "$rc"
    assert_stderr_contains "$proj names subagent-driven-development" "$CMD_SDD"
    assert_stderr_lacks "$proj does not name executing-plans" "$CMD_EXEC"
done
echo ""

echo "Test 42: the project routing file wins over the home file (first file found, keys never merged)"
HOME_EXEC="$WORK/home-exec"
mkdir -p "$HOME_EXEC/.claude/superpowers"
printf '%s\n' '{"mechanical":"haiku","parallelSession":"executing-plans"}' > "$HOME_EXEC/.claude/superpowers/model-routing.json"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$WORK/project")
rc=$(run_hook "$INPUT" HOME="$HOME_EXEC")
assert "project file without the key + home file with executing-plans → block" "2" "$rc"
assert_stderr_contains "project file wins → subagent-driven-development" "$CMD_SDD"
INPUT=$(make_wrong_options_input "$WORK/armed-via-skill.jsonl" "$WORK/noproject")
rc=$(run_hook "$INPUT" HOME="$HOME_EXEC")
assert "no project file + home file with executing-plans → block" "2" "$rc"
assert_stderr_contains "home file used → executing-plans" "$CMD_EXEC"
echo ""

echo "Test 43: a second plan after an in-session execution re-arms the guard"
cat > "$WORK/second-plan-after-execution.jsonl" <<'EOT'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1","description":"goal"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:subagent-driven-development"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"superpowers-extended-cc:writing-plans"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TaskCreate","input":{"subject":"Task 1 of plan 2","description":"goal"}}]}}
EOT
INPUT=$(make_wrong_options_input "$WORK/second-plan-after-execution.jsonl")
rc=$(run_hook "$INPUT")
assert "question after the second plan's TaskCreate → block" "2" "$rc"
echo ""

echo "=== Summary: $FAILED failure(s) ==="
exit "$FAILED"
