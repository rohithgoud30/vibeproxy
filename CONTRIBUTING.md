# Contributing

## Personal Fork Workflow

- Treat `rohithgoud30/vibeproxy` as the working repository and `origin/main` as the PR target unless explicitly told otherwise.
- Before opening a PR, fetch `upstream/main` and make sure the personal fork's `main` contains upstream `main` by ancestry.
- Put new feature or fix commits on top of the latest upstream-backed personal `main`.
- Open PRs against `rohithgoud30/vibeproxy:main`, not `automazeio/vibeproxy:main`, unless the user explicitly asks for an upstream PR.
- Do not cherry-pick upstream update commits into personal `main`; that copies changes without ancestry and can make GitHub show the fork as behind.
- If branch protection blocks a true rebase/force-push, merge `upstream/main` into the personal `main` lineage with a normal merge commit so GitHub shows `0 behind` and only ahead.
