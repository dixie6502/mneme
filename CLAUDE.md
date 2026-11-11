# mneme — project rules

Claude Code marketplace for dixie's information system. Design in
`ARCHITECTURE.md`; keep it in sync with the code.

## Public repo

- Never name a client, organization other than `dixie6502`, host, email or
  person. Use placeholders (`<owner>`, `<hostname>`). Only exception: the
  `LICENSE` copyright line for `alxn0`, required for the code copied from kit.
- `pre-commit` (gitleaks included) passes before every commit.

## Git

Own repo: commit and push directly to `main` once all checks pass.

## Layout

- `.claude-plugin/marketplace.json`: lists the plugins under `plugins/`.
- `plugins/<plugin>/`: one plugin per folder, with its own
  `.claude-plugin/plugin.json`. Scripts referenced via `${CLAUDE_PLUGIN_ROOT}`.
- Data never lives in the repo: `~/log`, `~/knowledge`, `~/memo`.
