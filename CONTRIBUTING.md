# Contributing to Muxbar

Thanks for helping! Bug reports, agent support and fixes are all welcome.

## How to contribute

1. Look for issues labelled [`good first issue`](https://github.com/ganeshpanaskar/muxbar/labels/good%20first%20issue)
   or [`help wanted`](https://github.com/ganeshpanaskar/muxbar/labels/help%20wanted), or open one
   to discuss a bigger change first. Questions go to [Discussions](https://github.com/ganeshpanaskar/muxbar/discussions).
2. Fork the repo, create a branch (`git checkout -b add-aider-preset`), make your change.
3. Run `make test`, then open a pull request against `main`. CI must pass before merging.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues
privately, see [SECURITY.md](SECURITY.md).

## Build and test

Muxbar builds with Apple's Command Line Tools alone (no Xcode):

```bash
make test      # unit tests
make install   # build, bundle, sign, install to ~/Applications, relaunch
```

`HOST=local scripts/e2e.sh` runs the end-to-end suite against an isolated test copy of the app
(`make bundle-test`) and its own tmux server. It only touches tmux sessions named `muxbar-e2e-*`.

## Adding or fixing an agent

- **Any CLI already works** through New Session → Other. Its status is read with generic screen
  rules (`StatusClassifier.classifyGeneric`); to recognise a new CLI by its process name, add it
  to `StatusClassifier.knownOtherAgents` in `Sources/MuxbarCore/StatusClassifier.swift`.
- **Deep support** (exact status from hooks, history search, resume, sleep) exists for Claude
  Code and Codex. Every agent-specific fact lives in `AgentAdapter` (`Sources/MuxbarCore/Agents.swift`):
  process detection, resume command, flags kept on resume. Adding an `AgentKind` case there and
  following the compiler errors is the way in; hooks live in `agent-plugin/` and
  `Sources/MuxbarCore/HookInstall.swift`, history in `Sources/MuxbarCore/History.swift`.
- Status patterns should be backed by a fixture: save real `tmux capture-pane -p -J` output to
  `Tests/MuxbarCoreTests/Fixtures/status/<status>-<name>.txt` (prefix = `working`, `waiting`,
  `idle`, `notclaude` or `unknown`; add a `.procs` file to override the process list).

## Releasing (maintainers)

Installed copies update themselves from GitHub Releases, so a release is what ships to users:

1. Bump `VERSION` in the `Makefile` (semver: patch = fixes, minor = features, **major = breaking**;
   major releases ask users before installing, the others install automatically).
2. Commit, then tag and publish: `git tag v0.2.0 && git push origin v0.2.0 &&
   gh release create v0.2.0 --generate-notes`.
3. The tag must match `VERSION`, otherwise installs keep seeing themselves as outdated.

## Guidelines

- Keep `MuxbarCore` free of UI code and unit-test new logic there.
- Match the surrounding style. Comments explain *why*, not *what*.
- Strip anything personal (hostnames, usernames, paths) from fixtures before committing.
- One focused change per pull request. Describe how you tested it.
