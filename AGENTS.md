# Latest

## Scope and workflow

- Complete the requested work, preserve unrelated changes, and keep explanations concise. Explicit user instructions take precedence over skill guidance. For analysis or review, inspect and report; implement only when requested. For fixes, make routine choices without unnecessary confirmation.
- Use `README.md` for commands and architecture. Search production code in `Latest/` and tests in `Tests/`; exclude generated build trees.
- Apply only relevant skill workflows and use repository commands. Keep checks and documentation proportional to the change; do not expand a small edit into a broad audit or publication workflow.
- Document current behavior. Store experimental logs and captures in `build/` unless they are reviewed test baselines. For long tasks, give a concise handoff at major phase changes with decisions, unresolved requirements, and evidence paths.

## Delegation

- Default to one agent. Delegate only a substantial, independent investigation that can save meaningful time or resolve a specific uncertainty. Small fixes, routine cleanup, builds, and release steps stay with the main agent.
- Start with one read-only subagent; use at most two for distinct investigations. Reuse an existing subagent for related follow-ups. Give each a bounded question, relevant paths and constraints, and request concise findings with file references. Subagents must not delegate further.
- For self-contained investigations, explicitly use `fork_turns="none"` and supply the necessary context. Use a limited history fork when recent discussion matters; use full history only when the task depends on it. With no or limited history, explicitly use `reasoning_effort="medium"` by default, `low` for simple discovery, and `high` or above only for difficult correctness questions. Full-history forks inherit the parent settings; do not choose them merely to inherit elevated reasoning. Honor explicit user model and reasoning choices.
- Keep implementation and final validation with the main agent. Do not repeat a completed investigation without conflicting evidence or a remaining gap, and do not run concurrent Xcode jobs against shared build products.

## Validation

- Run checks appropriate to implementation changes; use `./script/test.sh` for fast background app checks. Foreground interaction and visual tests are opt-in with `./script/test.sh --ui`; run them for affected UI behavior. Keep benchmarks separate. Repeat or broaden checks only for new changes, failures, or unresolved concerns.
- For UI changes, verify production appearance and affected interactions. For scrolling changes, cover key repeat, reversal, list edges, multiline rows, pinned headers, and mouse targeting. Compare original and candidate on the same system before updating visual references.
- Compare performance on the same hardware with a representative workload. Report unmet targets; a passing benchmark alone does not establish correct interaction behavior.

## Release and replacement

- Read or use release and app-replacement skills only for an explicit release or replacement request. Fixing, building, testing, or launching does not authorize publication or replacement.
- A replacement request authorizes shipping relevant unshipped changes. Check the latest published release against the current version first. If this fork has no published releases, fetch `origin/master` and use its version and source revision as the published-source fallback. Keep an already newer version; bump once only when relevant unshipped changes need a new version, and update release notes. Commit and push successfully before rebuilding and replacing. If already shipped, avoid an unnecessary bump or commit.
- Replacement does not run tests, visual comparisons, benchmarks, evaluations, or audits unless separately requested. Implementation validation belongs to the implementation task; replacement requires the build and installed-bundle verification.
- After replacement, verify the installed version and running app path.
