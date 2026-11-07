# Mermaid recipe for the architecture delta map

Both views are `flowchart LR`. Paste these classDefs first in every view:

```
flowchart LR
classDef neu    fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:2px
classDef gebaut fill:#dcfce7,stroke:#15803d,color:#14532d,stroke-width:5px
classDef mod    fill:#fef9c3,stroke:#ca8a04,color:#713f12,stroke-width:2px
classDef del    fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d,stroke-dasharray:6 4
classDef ctx    fill:#f1f5f9,stroke:#94a3b8,color:#334155
```

| Class | Meaning | Where |
|---|---|---|
| `neu` | new | both modes |
| `gebaut` | new and already present in the worktree | planned mode only — in the actual map everything is built, so the class is not used |
| `mod` | modified (renames too, label `old → new`) | both modes |
| `del` | deleted | both modes |
| `ctx` | untouched, shown because an edge needs it | both modes |

Attach a class with `:::neu` after the node, e.g. `SRV["Server<br/>health · SMTP"]:::mod`.

## Zones

Zones are `subgraph ID["Label"] … end`. Colour a zone by the majority status of
its blocks:

```
style ZONE fill:#f0fdf4,stroke:#15803d,color:#14532d,stroke-width:2px   %% mostly new
style ZONE fill:#fefce8,stroke:#ca8a04,color:#713f12                    %% mostly modified
style ZONE fill:#f8fafc,stroke:#cbd5e1,color:#334155                    %% context
```

A nested zone that is entirely new may use `fill:#ecfdf5`.

## Nodes and edges

- Node label = name, then `<br/>` and the one thing that matters (role, task
  number, schedule, "unchanged").
- Several files of one folder go into one node, separated by ` · `.
- Edge label = what flows or who calls whom: `-- "SQL" -->`, `-- "ssh deploy" -->`.
- Dashed edge `-. "describes" .->` = only describes, checks or points at.
- At most 25 nodes per view. Beyond that, bundle files into folder nodes and
  drop context nodes that carry no edge.
- Labels follow the language of the spec; translate the legend and the view
  titles in the HTML template when the spec is not in English.

## Mermaid initialisation

Mermaid 12.2.0 as an ESM import from cdnjs (already in the HTML template):

```html
<script type="module">
  import mermaid from "https://cdnjs.cloudflare.com/ajax/libs/mermaid/12.2.0/mermaid.esm.min.mjs";
  mermaid.initialize({
    startOnLoad: true,
    theme: "neutral",
    securityLevel: "loose",
    flowchart: { htmlLabels: true, curve: "basis", nodeSpacing: 30, rankSpacing: 50, useMaxWidth: false },
    themeVariables: { fontFamily: "system-ui, -apple-system, sans-serif", fontSize: "14px" }
  });
</script>
```

## Visual companion traps

The companion frame styles mockup text; three rules keep the map readable
(all three are in the template's `<style>`):

```css
.mermaid, .mermaid * { text-transform: none !important; letter-spacing: normal !important; }  /* frame upper-cases mockup text */
.mermaid svg { max-width: none !important; }   /* with useMaxWidth:false, keeps the natural size */
.mockup-body { overflow-x: auto; }             /* wide maps scroll instead of shrinking */
```

Write the filled template as a *fragment* (no `<!DOCTYPE`) to the companion's
`screen_dir`; the server wraps it in its frame. Fresh file name per map:
`architecture-delta-<topic>.html`, revisions `-v2`, `-v3`.

## Artifact wrapper

Without a running companion, wrap the fragment in this minimal document and
publish it as an artifact:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Architecture Delta</title>
<style>
  :root { --bg-primary:#f5f5f7; --bg-secondary:#ffffff; --bg-tertiary:#e5e5e7; --border:#d1d1d6; --text-primary:#1d1d1f; --text-secondary:#86868b; }
  body { margin:0; padding:16px; font-family:system-ui,-apple-system,sans-serif; background:var(--bg-primary); color:var(--text-primary); line-height:1.5; }
  h2 { font-size:1.5rem; margin:0 0 .5rem; }
  .subtitle { color:var(--text-secondary); margin:0 0 1.5rem; }
  .section { margin-bottom:2rem; }
  .mockup { background:var(--bg-secondary); border:1px solid var(--border); border-radius:12px; overflow:hidden; margin-bottom:1.5rem; }
  .mockup-header { background:var(--bg-tertiary); padding:.5rem 1rem; font-size:.75rem; color:var(--text-secondary); border-bottom:1px solid var(--border); }
  .mockup-body { padding:1.5rem; }
</style>
</head>
<body>
<!-- fragment goes here -->
</body>
</html>
```

The fragment's own `<style>` block and module script travel with it.
