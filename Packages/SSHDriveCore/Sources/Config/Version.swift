/// The release version, generated from the repository's `VERSION` file by
/// `scripts/set-version.sh`. Edit `VERSION` and re-run that script; never edit this file.
///
/// Everything that reports a version reads it from here: the CLI's `--version`, the
/// agent's `version` command, the helper crate (`helper/Cargo.toml`, stamped by the same
/// script) and the Homebrew cask. `sshDriveXPCInterfaceVersion` is a separate number - it
/// describes the XPC protocol, not the release.
public enum SSHDriveVersion {
    public static let string = "0.1.10"
}
