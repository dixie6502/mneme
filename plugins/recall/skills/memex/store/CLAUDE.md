# memex — rules of the store

dixie's persistent memory: facts inferred from the session log, loaded on demand
with `/memex find`. Design: the mneme marketplace's `ARCHITECTURE.md`.

- Derived only: entries are written by the recall plugin's sweep from the log,
  never by hand or directly by a session. Corrections go through a session.
- Layers: `global/` (the agent, its hosts, devices, tools; no project) and one
  folder per owner, named as in `~/<Host>/<owner>/`. One `#moc` index per layer.
- Links point upward only: owner → global. Global never links to an owner; an
  owner never links to another owner. Global content never mentions an owner's
  private matters.
- One entry per thing; basenames unique across the store (`[[wikilinks]]` by
  basename). Owner-layer entries are named `<owner>-<slug>.md`, so they never
  collide with global or another owner's. Rename or delete only with `wkref mv` / `wkref rm --root ~/memex`.
- `.dream/proposals.json`: the dream pass's consolidation proposals; one is applied
  only after the user approves it (`/memex apply`).
- `memex.sh check` passes before every commit. Local git only, no remote yet.
