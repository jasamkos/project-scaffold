# project-scaffold

Claude Code skill `project-scaffold-init`: sets up a `.scaffold/` context layer (project summary, decisions, per-task work notes) in a repo and installs hooks that keep it current as work happens. Just-me mode stays untracked; everyone mode is committed so the whole team sees current status. Optional status board artifact. Design: `docs/specs/2026-11-04-auto-updating-scaffold-design.md`.

Install the skill: `ln -s "$PWD/skill" ~/.claude/skills/project-scaffold-init`. Checks: `make check`.
