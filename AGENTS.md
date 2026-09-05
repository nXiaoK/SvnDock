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
- This authorization covers local commits. Push only when the user requests it.
- If a commit fails, resolve the cause when possible without bypassing hooks or
  inventing Git identity settings. Report any remaining blocker explicitly.

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
