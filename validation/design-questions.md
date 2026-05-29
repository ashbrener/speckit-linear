# Open Design Questions — NOT RATIFIED, DO NOT IMPLEMENT

**These are unresolved discussion items. None is a spec, an FR, or a task.**
Nothing in this file is scoped for implementation. To pursue any item
here, it MUST first go through `/speckit-specify` as its own spec and
run the full lifecycle (clarify → plan → tasks → implement). The
`/speckit-*` commands and the bridge reconciler only ever act on
`specs/NNN-feature/` directories and `tasks.md` files — this document
is inert with respect to every automated path. Treat it as a parking
lot for thinking, nothing more.

Each question links to a GitHub issue where discussion happens.

---

## Q1 — Should specs map to Linear Projects instead of Issues?

**Tracking issue**: [#17](https://github.com/ashbrener/spec-kit-linear/issues/17)
**Status**: OPEN — discussion only. Recommendation leans "keep current model as default; re-evaluate as a possible spec 004 after spec 003 lands."

### Current model (ratified in spec 001)

| Filesystem | Linear |
|---|---|
| Consumer repo | **Project** |
| Spec (`specs/NNN-feature/`) | **Issue** (label `speckit-spec:NNN`) |
| Task phase (`## Phase N`) | **sub-issue** |
| Task | **checklist item** |

### Proposed alternative

| Filesystem | Linear |
|---|---|
| Consumer repo | **Team** (or unmapped) |
| Spec | **Project** |
| Task phase | **Issue** |
| Task | **sub-issue** or checklist item |

### Where spec→Project wins

- Task phases become first-class **Issues** — assignable, estimable, commentable, with their own workflow states + cycle assignment. Today a task phase is a weaker sub-issue and a task is just a checklist line (no assignee, state, or comments).
- Linear's Project-grade features light up: Project updates, milestones, target dates, progress graphs, documents. A spec — a body of work with phases — is arguably more Project-shaped than Issue-shaped.
- Scales better for large specs: a 10-phase / 80-task spec is cramped as 1 Issue + 10 sub-issues + 80 checklist lines; native as a Project with 10 Issues.

### Where the current spec→Issue model wins

- `repo → Project → Issue` is intuitive ("this repo's work, these specs").
- Cross-repo unified view is trivial — all specs are Issues, filterable by the `speckit-spec:NNN` label in one place. Specs-as-Projects turns "all specs everywhere" into a Project-list view that Linear filters less gracefully.
- **Lifecycle states map cleanly to an Issue's state machine** (Specifying → … → Merged, nine states). Linear Projects expose only a coarse status enum (Planned / Started / Completed) that cannot represent the nine lifecycle phases.
- Projects are heavier objects; hundreds of specs-as-Projects could clutter the workspace Project list.

### Possible resolution

Not necessarily either/or — a per-repo config mode (`spec_granularity: issue | project`) could offer both, but that roughly doubles the reconcile surface and the data model. Significant lift; only worth it if dogfood data shows the Issue model genuinely strains for large specs.

### Recommendation (discussion, not a decision)

Keep spec→Issue as the shipping default. The lifecycle-state-on-Issue advantage is concrete, and the founding use case is "many repos, many specs, one pane" — which spec→Issue serves directly. Re-evaluate spec→Project as a possible **spec 004** after spec 003 (drift-aware authority) ships and there is real dogfood evidence on how cramped large specs feel in practice.
