# Architecture map — <project>

Longest path prefix wins. A prefix is matched literally, so end folder
prefixes with `/`. Blocks with zone `—` appear only in the repository view.

| Prefix          | Block            | Zone            |
|-----------------|------------------|-----------------|
| server/         | Server (Rust)    | Host            |
| deploy/ansible/ | Ansible playbook | Operator's Mac  |
| docs/           | Documentation    | —               |

Stable connections of the system view (optional). They are drawn in every
map so they are not reinvented per spec.

| From          | To            | Label          |
|---------------|---------------|----------------|
| Server (Rust) | Postgres      | SQL            |
