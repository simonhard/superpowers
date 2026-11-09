---
name: tracing-acceptance-criteria
description: Use when a design needs its acceptance criteria, when finishing a development branch, or when your human partner asks which tests cover which criteria
---

# Tracing Acceptance Criteria

## Overview

The criterion belongs to your human partner, the test to the project, the
overview to the script. Criteria are written while the design is made, carry
their test names in the spec, become permanent tests in the project's own
suite, and are shown before the merge: per criterion, the tests that cover it.

**Core principle:** every line and every number of the overview comes from
`scripts/trace-acceptance.sh`, never from memory.

| Mode | Called from | Result |
|---|---|---|
| **define** | brainstorming, after the design is approved | the spec section with the criteria table |
| **trace** | finishing-a-development-branch, or when your human partner asks | the overview: criterion → tests with file and line |

## The table

One contract for everyone: brainstorming writes it, writing-plans and the
reviewers read it, the script parses it.

```markdown
## Acceptance Criteria

<!-- acceptance-criteria -->
| ID | Criterion | Origin | Level | Tests |
|---|---|---|---|---|
| AC-1 | Only the orders matching the filter are exported | partner | CLI | `itExportsOnlyFilteredOrders` |
| AC-2 | A user who logs in stays logged in after a reload | proposal | API | `itLogsAUserInAndRefreshes`, `itKeepsTheSessionAfterReload` |

**AC-1** — Given: orders 1 (open) and 2 (paid). When: `export --status open`.
Then: the file holds order 1 only.

**Not part of this:** …
```

1. The marker stands alone on its line, directly above the header row. The
   table ends at the first line that does not start with `|`. A marker inside
   a code fence does not count.
2. Exactly five columns in this order; headers may be in the spec's language.
3. ID: letters, dash, number (`AC-1`, `AK-1`), unique.
4. Origin: your human partner's criteria carry their name or "partner"; yours
   carry "proposal" in the spec's language.
5. Level: `API`, `UI`, `CLI`, `unit` or `manual`, always in English. `manual`
   rows are not searched.
6. Tests: names in backticks, comma-separated; a string-named test
   (`it('logs in')`) is named by its string. For `manual`, free text;
   backticks in it are not searched.

## Writing criteria (define)

1. **Take theirs verbatim.** Criteria your human partner gave stand word for
   word, origin their name or "partner". Never reword them; if one is unclear,
   ask instead of smoothing it.
2. **Add your own**, origin "proposal":
   - from the view of whoever uses the result: a person, a calling system,
     an operator;
   - observable behaviour; no file, class, function or variable names in the
     criterion text;
   - one Given/When/Then example with real values per criterion;
   - error and edge cases as criteria of their own;
   - typically 3–9 criteria. More suggests a package that should be split.
3. **Name the tests in the project's style.** Read two or three existing
   tests first. No tests yet: `it<Behaviour>` (`itRedirectsToStart`).
4. **Present the list in chat** as its own design section and ask what to add
   or strike. The spec is written after the answer.
5. **Write the section** into the spec, before the Architecture Delta, with
   one line "Not part of this".

Bounded changes: the criteria and test names go into the short in-chat
design; at the end of the implementation, list criterion → test → file. No
script, no overview. Spikes get no criteria.

## Tracing (trace)

1. **Find the spec:** the plan's `Spec:` line; otherwise ask your human
   partner for the path.
2. **Run the script** from the repository:
   `bash <this skill's directory>/scripts/trace-acceptance.sh --spec <spec> --base <base-branch>`;
   leave out `--base` only when no base is known. Commit first: tests without
   criterion are read from committed history.
3. **Read the exit code.** 0: go on. 3: say in one sentence that the spec has
   no acceptance criteria, naming the path, and stop here. 2: show the
   message from stderr and stop; never draw an overview from memory.
4. **Read the rows.** `#criterion` rows (id, origin, level, text), one row
   per test (`found`, `missing`, `skipped` or `manual`, name, `file:line`,
   hits), `#unmapped` rows (new tests without criterion), one `#counts` row.
5. **Fill** `templates/acceptance-overview.html`: counts, one block per
   criterion with its tests (✔ found, ⚠ skipped, — missing), the manual
   criteria with "you check this yourself" and their Given/When/Then from
   the spec, the unmapped tests. A name with more than one hit shows its hit
   count. Labels follow the language of the spec.

## Showing the overview

In this order:

1. **Visual companion**, when its server is running: write the filled
   template as a fragment to its `screen_dir` (the brainstorming skill's
   visual-companion.md says how).
2. **Artifact**, otherwise: follow the host's artifact contract and carry
   over the fragment's content.
3. **Text in chat**, when neither exists: one line per criterion, one
   indented line per test: mark, name, `file:line`.

Fresh file name per overview: `acceptance-<topic>.html`, revisions `-v2`,
`-v3`. Asked for outside the finishing step, show the overview without
asking for acceptance; acceptance belongs to the finishing step.

## Hard rules

- Every line and every number of the overview comes from the script output;
  only the Given/When/Then of manual criteria comes from the spec.
- Never change a status by hand. A skipped test is skipped until the marker
  is gone.
- Never reword your human partner's criteria.
- A test that has the right name but checks its criterion from the inside
  (an internal helper instead of the interface, page or command) does not
  cover it.

## Red Flags

| Thought | Reality |
|---|---|
| "They named no criteria, so there are none" | Write them yourself, marked as proposal. |
| "I'll phrase their criterion a little more precisely" | Their wording stays. Your precision is a proposal of its own. |
| "The test has the right name, that's enough" | It must check the criterion from the outside, at its level. |
| "I know which tests exist" | Run the script. The overview is read, not remembered. |
