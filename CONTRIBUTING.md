# Contributing to Muxbar

Thanks for helping! Bug reports, agent support and fixes are all welcome.

## Build and test

Muxbar builds with Apple's Command Line Tools alone (no Xcode):

```bash
make test      # unit tests
make install   # build, bundle, ad-hoc sign, install to ~/Applications, relaunch
```

`HOST=local scripts/e2e.sh` runs the end-to-end suite against the installed app and local tmux.
It only touches tmux sessions named `muxbar-e2e-*`.

## Adding or fixing an agent

- Presets live in `Sources/MuxbarCore/Agent.swift` (`AgentProfile.builtins`): command, process
  names, resume/continue commands.
- Status cues live in `Sources/MuxbarCore/StatusClassifier.swift`. Each pattern should be backed
  by a fixture: save real `tmux capture-pane -p -J` output to
  `Tests/MuxbarCoreTests/Fixtures/status/<status>-<name>.txt` (prefix = `working`, `waiting`,
  `idle`, `notclaude` or `unknown`; add a `.procs` file to override the process list).
- Conversation discovery (for **Continue Agent Session…**) lives in
  `Sources/MuxbarCore/Conversations.swift`. It's a POSIX `sh` script run on the host, plus a
  parser, and both are tested in `CoreTests.swift`.

## Guidelines

- Keep `MuxbarCore` free of UI code and unit-test new logic there.
- Match the surrounding style. Comments explain *why*, not *what*.
- Strip anything personal (hostnames, usernames, paths) from fixtures before committing.
- One focused change per pull request. Describe how you tested it.
