# Packaging

`cask/sshdrive.rb` is the cask, and the source of truth for every stanza in it.
`scripts/set-version.sh` stamps its `version` from the repository's `VERSION`
file; its `sha256` belongs to a built DMG and is the previous release's until a
release fills it in.

The Homebrew tap lives in its own repository, `alecdwm/homebrew-tap`, because
`brew tap alecdwm/tap` resolves to that name. `.github/workflows/release.yml`
renders the cask with the notarized DMG's version and sha256 and pushes it there
as `Casks/sshdrive.rb`, which is the file name Homebrew resolves the token to.

A checkout of the tap is kept at `homebrew-tap/` for reading and for running
`brew style` against; that directory is ignored by this repository and nothing
in it is a source of truth. `docs/release.md` is the procedure.
