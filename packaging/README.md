# Packaging

The Homebrew tap lives in its own repository, `alecdwm/homebrew-tap`, because
`brew tap alecdwm/tap` resolves to that name. A checkout of it is kept at
`packaging/homebrew-tap/` for editing alongside the code it installs; that
directory is ignored by this repository.

`scripts/release.sh` prints the `version` and `sha256` lines the cask needs
after each notarized build. See `docs/release.md`.
