# Project instructions

## Automatic Git commits

- After resolving each issue or completing a coherent requested change, run the
  relevant verification, review the final diff, and create a local Git commit
  before reporting completion. This is standing authorization; do not ask for
  confirmation each time. Follow an explicit request to defer or skip a commit.
- Commit independently completed issues separately. Keep dependent changes
  together when splitting them would leave an incomplete or broken revision.
- Inspect both the working tree and index before staging. Stage only files or
  hunks belonging to the issue being completed. Preserve unrelated or pre-existing
  changes and staged work; do not sweep them into a commit with `git add .` or
  `git add -A`.
- Fix failures caused by the change before committing. If relevant verification
  cannot run because of the environment or a known pre-existing failure, record
  the limitation accurately in the commit body and final response. Do not claim
  that unavailable checks passed. Documentation-only changes need a diff review,
  not an application test run.
- Feature updates and bug fixes also have standing authorization to package the
  App and push after verification, following the workflow below. Follow an
  explicit request to defer or skip packaging or pushing.
- If a commit fails, resolve the cause when possible without bypassing hooks or
  inventing Git identity settings. Report any remaining blocker explicitly.

## Automatic App packaging and pushes

- After completing requested feature updates or bug fixes, verify the changes,
  review the working tree and index, and create the relevant local commits.
  Then package the committed source and push the completed work without asking
  for confirmation. For multiple related changes in one task, package the final
  revision and perform one push after all relevant checks succeed.
- Use `Scripts/build-release-app.sh` for the current Mac architecture, placing
  the portable App in a new version- and revision-labelled directory under
  `dist/`. Also create a ZIP archive using `ditto` so the App can be copied or
  installed easily. Preserve existing packages and never commit build artifacts.
- Check the package's architecture, App and Finder extension signatures, and
  embedded source revision. Verify the ZIP can be extracted with its App
  signature intact. Package the intended committed code only; preserve unrelated
  uncommitted changes and use an isolated checkout when needed. Rebuild if the
  packaged source changes before the push.
- Push the intended branch to its configured remote using a normal,
  non-forced push only after packaging and verification succeed. Preserve remote
  changes if the push is rejected; inspect and resolve the cause safely instead
  of overwriting history. Reverify and repackage if integration changes source.
- If a required check, packaging step, or push fails, resolve the cause when
  possible and report any remaining blocker accurately. Never report an
  unverified package or an unsuccessful push as completed.
- Provide clickable paths to the App and ZIP, the supported architecture and
  macOS version, relevant verification results, the commit hash and subject,
  and the push result. Note signing or runtime requirements that affect use.
- This workflow applies to feature updates and bug fixes. Read-only reviews,
  planning, questions, and documentation-only changes do not require packaging
  or pushing unless the user requests it.

## Commit message quality

- Write every commit subject and body in English, in a professional developer
  voice focused on the code and its behavior.
- Use `type(scope): imperative summary`, with an appropriate type such as `fix`,
  `feat`, `refactor`, `docs`, `test`, or `chore`. Omit the scope when it adds no
  useful context. Aim for a subject of 72 characters or fewer.
- Describe the concrete resulting behavior. Avoid vague subjects such as
  "Update code", "Fix issue", or "Address feedback", conversational history,
  self-praise, and claims not supported by the implementation.
- Add a body when useful to explain the problem, why the chosen change resolves
  it, important tradeoffs, and meaningful verification or limitations. Use real
  paragraph breaks; omit a body for a simple, self-explanatory change.
- Example: `fix(ui): expand commit diff previews and preserve draft state`.
- In the final response, include the created commit's short hash and English
  subject, along with the relevant verification result.
