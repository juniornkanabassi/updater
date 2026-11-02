# Review guide

How to review changes to Updater. The shared rules (lanes, check results, finding format, the three-round checkpoint, approval of an exact revision) are in the owner's JuniorOS `03 Skills/Review workflow.md`. This file holds only what is specific here. Severity is Important, Nit (at most three, never blocking) or Pre-existing. Start the summary with the count. 0 findings is a valid result.

## Failure here means

- An app is lost: the old bundle is removed before the new one is verified.
- Success is reported without the installed bundle's version changing on disk.
- A running app is not quit cleanly, or its unsaved-work prompt is skipped.
- Admin rights are stored or asked for outside the system prompt.
- A test updates one of Junior's real apps.

## Always High

Installing and replacing bundles, `UpdateInstaller/`, privilege handling, release-note signing, `install.sh`, `build.sh`.

## Always check

- Upstream (Latest) fixes are pulled deliberately and their diff reviewed like any other change.

## Check results

Each check is listed with its last result in the review workflow rollout (1 Nov 2026). NOT RUN means it was not run then, and the project's `Validation.md` or memory holds older runs. Report every check you run as PASS, FAIL, NOT RUN or NOT APPLICABLE with the revision.

| Command | Proves | 1 Nov |
|---|---|---|
| `./script/test.sh` | the unit test plan | NOT RUN |
| `./script/test.sh --integration`, `--ui` | integration and UI plans | NOT RUN |
| `./script/lint.sh` | lint | NOT RUN |
| `.github/workflows/ci.yml` | the fork's CI on GitHub | not inspected remotely |

## Skip

`Frameworks/`, `build/`, `Tests/VisualBaselines/` images.
