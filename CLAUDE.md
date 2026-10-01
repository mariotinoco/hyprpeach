# Working in hyprpeach

A collection of Omarchy plugins, installed as one: the root is an invisible `hyprpeach`
service plus the `hyprpeach` command, and each plugin lives in `plugins/<name>/`, which
`hyprpeach plugin add <name>` links into Omarchy's plugins folder. `init.lua`, the
desktops library, stays at the root, where Hyprland and hand installs load it. The machine-wide
ADRs in `~/.claude/CLAUDE.md` govern how the code is shaped. This file covers only
what is particular to shipping *this* repository.

## Commits

Conventional Commits, carrying the release on the subject line when the commit is one:

```
feat(1.0.0): make a desktop a set of workspaces, one per monitor
fix(1.0.1): keep a pinned window on the panel it was pinned to
docs: record the commit and release conventions
```

The subject says what changed for someone using it. The body says **why**, in a
dozen lines or so — rarely more.

**The log is not where the explanation lives.** It belongs in the source, beside the
code it explains, where it is read by the next person to touch that code and stays
true when the code moves. A commit message that reproduces a comment has made a
second copy of it to keep in step, and the copy in the log is the one that silently
goes stale. Say what changed and why it had to; leave the reasoning where it works.

Cite the compositor file and version when a claim is about Hyprland's internals, and
say what was measured rather than what was intended — a line each, not a section
each.

No `Co-Authored-By` trailers, and no other AI attribution. The author is the author.

## Releases

hyprpeach's own version is the collection's, and it is about what a person has to
do: removing a plugin, a plugin's major release, or changing how hyprpeach installs
is major; adding a plugin or a plugin's minor release is minor; everything else is a
patch. A rename is a patch ONLY because the upgrade carries it: list it in
`RENAMED_PLUGINS` in `bin/hyprpeach` -- `migrate` moves the link, bar place, enabled
entry and files, and the old name keeps working in `plugin add` -- and never take an
entry out, because an install can skip releases. It lives in `manifest.json` and the
version-pinned commands in `README.md` — they move together or the release lies about
itself. The README's table of what a version promises is the contract; keep it true.

**Only releases reach `main`.** Omarchy installs and updates to the newest commit on
it, so a commit there is shipped to everyone the next time they update, released or
not. Code lands on `main` together with its release; documentation may follow alone.

**Each plugin under `plugins/` is versioned on its own**, in its own `manifest.json`,
against its own surface — for desktops, the `peach.*` functions, `setup()` options and
the keymap. It ships when hyprpeach ships, because Omarchy installs the
whole repository at `main`; its version says what changed in *it*. A commit that
releases one says so on the subject line — `feat(ports-0.2.0): …` — and a commit that
releases both carries hyprpeach's.

Tag annotated: `vX.Y.Z` for hyprpeach, `<name>-vX.Y.Z` for a plugin. Only hyprpeach's
tags match `^v`, which is what a 1.x `hyprpeach upgrade` searches for — a plugin tag
shaped like a release would be offered to it as one. **Never re-point a published tag.** Consumers pin by tag and
fetch by name, so a moved tag leaves a clone reporting itself correctly pinned while
running code that exists nowhere. That has already happened here once, and nothing
noticed for a whole release.

**`npm run release` is the release**, and it is how one is done: it checks the tree,
the version and README's pins, runs every suite, pushes `main` before the tags,
verifies each on the remote, and publishes the Releases. Its header lists every rule
it enforces; a rule is changed there, not by hand. Each tag's notes are
`releases/<tag>.md` — first line `# title`, then the notes — written and reviewed
before releasing. The notes are the only part of this project most people will ever
read: what changed for someone using it, not what changed in the source; no commit
hashes, no file paths.

Before a release, `npm run local-upgrade` puts the committed HEAD on this machine the
way an update would, and the change is checked there first.

## Tests

`npm test` runs every suite below; a release refuses to publish without it passing.

`lua tests/hyprpeach.test.lua` — no compositor, a stubbed `hl`.
`bash tests/install.test.sh` — the install, the 1.x upgrade, and `hyprpeach plugin`.
`bash tests/ports.test.sh` — the ports reader and its model, against a fake `ss`.
`bash tests/overview.test.sh` — the overview's model: desktops, windows, grid.
`cargo test --manifest-path plugins/animated/renderer/Cargo.toml` — the animated desktops: every switch the same step forward, nothing longer than four, and where each monitor looks from.
All green before a release.

**A test never reaches the machine it runs on.** One did: the 1.x installer test
redirected its paths but ran the real `omarchy` under the real `HOME`, and replaced
the tester's own bar plugin with a clone of the sandbox, whose origin was a directory
deleted a second later. So a test sets `HOME` to its sandbox and puts fakes for
anything that reaches a running process — `omarchy-shell`, `hyprctl` — first on
`PATH`, and refuses to start unless they are what resolves. Scripts that only touch
files under `HOME` run for real.

They exist to pin down what is **invisible when wrong**. A paired switch firing in the
wrong sequence looks exactly like one that is not, until a window lands on the wrong
screen; an installer whose marker match silently fails looks like it worked, until the
config has four copies of the same block in it. Both were real. When a test needs its
stub or sandbox to model the real thing, teach the stub — never assert something the
real thing would not do.

A test that has never been seen to fail has not been shown to test anything. Break the
fix on purpose, watch the test go red, put it back.

**No suite reaches the bar or the overlay.** They are QML in another process, and
every visual regression this project has shipped went out with the suites green: tiles filling the bar edge to edge on a gapless desk, the strip sitting
five pixels off from every other icon in the panel, a padlock legible as a shape and
illegible as a meaning. Each was found by taking a screenshot and looking at it, and
none of them could have been found any other way.

So anything that changes what the bar or the overlay draws is verified on a running
desk before it is tagged — `grim`, crop, look. Measure against something: the other
widgets' centres, the tile's own edges, the bar's reserved width. "It looks fine" has
been wrong every time it mattered.

## Compositor bugs

Most of this library is Hyprland assuming a single monitor. Read the Hyprland source
at the version actually running and reproduce against a live compositor before
writing a workaround: the mechanism is almost never the obvious one, and a workaround
built on a guess will look like it works.

Prefer a repair that works *with* the compositor's mechanism over one that fights it.
The first survives upstream fixing the bug; the second breaks when they do.
