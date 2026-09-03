# Remote helper (milestone 9, tier 2)

Placeholder. The Rust helper crate lives here: a small static binary, cross-compiled in
CI (Linux and FreeBSD with `cross` in a Linux job, `darwin/arm64` natively on the macOS
job), deployed over SFTP into the server, verified by hash, and speaking NDJSON back over
an exec channel. See DESIGN.md section 6.4 tier 2 and section 10.1.

Nothing is built from this directory yet. The built binaries and their sha256 manifest end
up in `SSH Drive.app/Contents/Resources/helper/`.
