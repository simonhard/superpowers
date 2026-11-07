---
name: mapping-architecture-delta
description: Use when a spec is finished and needs its architecture delta before the go decision, when finishing a development branch, or when your human partner asks what a change touches
---

# Mapping the Architecture Delta

## Overview

Your human partner approves blocks and their connections, not file lists.
This skill draws the software a change touches in two views — **system view**
(what runs afterwards and how it is connected) and **repository view** (which
parts of the repository appear or change) — in four colours (new, modified,
deleted, context) with one counts row above. The same map is drawn twice:
from the spec before the go, and from the real git diff when the branch is
finished.

**Core principle:** every number and every colour comes from the spec's file
list or from `scripts/classify-diff.sh`, never from memory.

## Two modes

| Mode | Input | Output |
|---|---|---|
| **planned** | the spec's file list and blocks | section **Architecture Delta** at the end of the spec |
| **actual** | `scripts/classify-diff.sh --base <base-branch>` | the same map, plus the three deviation lists |

## Procedure

1. **Load the map file** `docs/superpowers/architecture-map.md` (template:
   `templates/architecture-map.md`). If it is missing, create it from the
   repository's top-level folders and the blocks the spec names, then go on.
2. **Get the file list.** Planned: every file the spec creates, modifies or
   deletes. Actual: from the repository root run
   `bash <this skill's directory>/scripts/classify-diff.sh --base <base-branch>`;
   it prints one TSV row per file (status, path, block, zone), a `#counts`
   row and one `#unmapped` row per path the map does not cover. Exit 2 means
   no base: stop and ask for the base branch.
3. **Status per file** — see Status rules.
4. **Status per block.** Roll files up by the map file's longest-prefix rule.
   Add a map row for every `#unmapped` path *before* drawing.
5. **Draw the system view.** Running blocks inside zone subgraphs, edges
   labelled with what flows or who calls whom. Stable edges come from the map
   file's second table.
6. **Draw the repository view.** Folders as subgraphs, files or file bundles
   as nodes, dependencies as edges.
7. **Finish.** Counts row, show the map, write the spec section (planned) or
   the deviation lists (actual). Colours, classDefs, zones, node and edge
   rules: `references/mermaid-recipe.md`.

## Status rules

File: `A` → new, `M` → modified, `D` → deleted, `R` → modified with label
`old → new`; anything untouched is context.

Block: all files new → new; all deleted → deleted; otherwise modified;
nothing touched → context, drawn only when an edge needs it.

Planned mode only: a planned new file that already exists in the worktree →
built (thick border). The actual map has no built class — everything in it
is built.

## Showing the map

In this order:

1. **Visual companion**, when its server is running: fill
   `templates/architecture-delta.html` and write it as a fragment to the
   companion's `screen_dir`.
2. **Artifact**, otherwise: wrap the fragment as the recipe shows and publish.
3. **Mermaid in the spec**, when neither exists: the spec section is the
   deliverable, and the gate text says so.

Fresh file name per map: `architecture-delta-<topic>.html`, revisions `-v2`,
`-v3`.

## Comparing planned vs actual (actual mode only)

Find the planned map: plan → its `Spec:` line → spec → section
"Architecture Delta" or "Architektur-Delta". Then list, by block:

- touched, but not planned
- planned, but not touched
- status differs from the plan (e.g. planned modified, actually new)

If no planned map exists, say "no planned map found at <paths searched>" and
show the actual map alone.

## Hard rules

- Numbers come from the script or from the spec's file list. Never estimate.
- At most 25 nodes per view; beyond that, bundle files into folder nodes and
  drop context nodes without an edge.
- Labels follow the language of the spec.
- No file is drawn outside the map file. Extend the map file first.
- The map is what your human partner approves; the file list is its source,
  not its substitute.

## Red Flags

| Thought | Reality |
|---|---|
| "The spec lists the files already" | Your human partner reads blocks and connections, not file lists. |
| "The diff speaks for itself" | A map was approved. The same map, drawn from the diff, is what gets accepted. |
| "Too small for a map" | Then it takes five minutes to draw. |
| "I know roughly how many files changed" | Run the script. Numbers are read, not remembered. |
| "I'll put the unmapped files where they probably belong" | Add the map row first; the next spec inherits it. |
