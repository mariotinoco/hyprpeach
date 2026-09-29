# Working in hyprpeach

One Lua library, `init.lua`, plus its tests and an optional Omarchy bar strip. The
machine-wide ADRs in `~/.claude/CLAUDE.md` govern how the code is shaped. This file
covers only what is particular to shipping *this* repository.

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

Semantic versioning against the `peach.*` surface and the keymap: a changed chord or
signature is breaking, a new capability is minor, everything else is a patch. The
version lives in `manifest.json`, `install.sh`'s default `TAG`, and the install
commands in `README.md` — they move together or the release lies about itself.

Tag annotated, `vX.Y.Z`. **Never re-point a published tag.** Consumers pin by tag and
fetch by name, so a moved tag leaves a clone reporting itself correctly pinned while
running code that exists nowhere. That has already happened here once, and nothing
noticed for a whole release.

**A release is not shipped until GitHub says so.** Pushing a tag does not create a
Release — the Releases page keeps showing the last one somebody published by hand, so
the project reads as abandoned at whatever version that was while four newer tags sit
in the repository unmentioned. Finish every release:

```bash
git push --force-with-lease origin main
git push origin vX.Y.Z
git ls-remote origin "refs/tags/vX.Y.Z^{}"   # must equal the commit you tagged
gh release create vX.Y.Z --title "vX.Y.Z — <the subject line>" --notes "..."
```

**Check the middle line landed before publishing.** `git push origin vX.Y.Z` is not
idempotent: a tag the remote already has is silently left alone, exit 0, no output
worth reading. So a tag pushed before a final amend keeps pointing at the commit
before it, `main` moves on without it, and a Release published against that tag pins
code nobody reviewed while looking entirely correct. That is what happened to v1.2.0
— pushed, wrong, unnoticed until the tag was compared with `main` by hand. A tag that
has already gone out and is wrong is not repointed; it is deleted and the next version
carries the fix.

The notes are the only part of this project most people will ever read. Say what
changed for someone using it, not what changed in the source; no commit hashes, no
file paths. `gh release list` against `git ls-remote --tags origin` is the check that
they agree.

## Tests

`lua tests/hyprpeach.test.lua` — no compositor, a stubbed `hl`.
`bash tests/install.test.sh` — no machine, a sandboxed clone and entry file.
Both green before a release.

They exist to pin down what is **invisible when wrong**. A paired switch firing in the
wrong sequence looks exactly like one that is not, until a window lands on the wrong
screen; an installer whose marker match silently fails looks like it worked, until the
config has four copies of the same block in it. Both were real. When a test needs its
stub or sandbox to model the real thing, teach the stub — never assert something the
real thing would not do.

A test that has never been seen to fail has not been shown to test anything. Break the
fix on purpose, watch the test go red, put it back.

**Neither suite reaches the bar strip or the overlay.** They are QML in another
process, and every visual regression this project has shipped went out with both
suites green: tiles filling the bar edge to edge on a gapless desk, the strip sitting
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
