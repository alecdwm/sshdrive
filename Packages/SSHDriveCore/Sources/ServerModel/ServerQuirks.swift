import Foundation

/// A row of `docs/quirks/servers.md`, by id.
///
/// The catalog is the source of the rules; this type is how a rule in `ServerModel` and an
/// assertion in `Tests/ServerModelTests` cite the row they defend. Ids are **stable for
/// ever** (`docs/quirks/README.md`): never reused, never renumbered, and a behaviour that
/// stops being true keeps its id and gains a measurement saying so.
public struct ServerQuirkID: Sendable, Hashable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// The `SQ-###` rows `ServerModel` implements, with the one-sentence statement from
/// `docs/quirks/servers.md` beside each so a reader of the model never has to leave it.
///
/// This is not a second source of truth: `docs/spikes/results.md` measures, the Markdown
/// catalog records, and this enum only names. `ServerQuirks.implemented` is what
/// `ServerModelQuirkCoverageTests` checks against the Markdown file, so a row that loses
/// its rule here is a test failure rather than a silent gap.
public enum ServerQuirks {

    // MARK: find and the sweep

    /// No busybox has `find -cmin`.
    public static let noBusyboxCmin: ServerQuirkID = "SQ-001"
    /// busybox `find --version` prints an error and **exits 0**.
    public static let busyboxFindVersionExitsZero: ServerQuirkID = "SQ-002"
    /// busybox `find` has no `-printf` either.
    public static let noBusyboxPrintf: ServerQuirkID = "SQ-003"
    /// A busybox `-cmin` fails the whole sweep rather than losing a field.
    public static let busyboxCminFailsTheSweep: ServerQuirkID = "SQ-004"
    /// `-mmin` misses a ctime-only change.
    public static let mminMissesCtimeOnly: ServerQuirkID = "SQ-005"
    /// The time test and `-printf` each cost a `stat` per entry.
    public static let findTimeTestCostsAStat: ServerQuirkID = "SQ-006"
    /// `find` has no portable `--`; every root is spelled `./name`.
    public static let findHasNoPortableDashDash: ServerQuirkID = "SQ-007"
    /// A container cannot have its clock skewed, so `clockOffset` is model-only coverage.
    public static let containersShareTheHostClock: ServerQuirkID = "SQ-054"
    /// A root whose bytes are not valid UTF-8 cannot travel through `set --` at all, so it
    /// is left out of the `find` argv and listed at tier 0 in the same cycle.
    /// `FakeSFTPServer.putRawName` is what lets such a name exist in the model at all.
    public static let nonUTF8RootCannotReachFind: ServerQuirkID = "SQ-055"

    // MARK: process lifetime and teardown

    /// A bare background process survives an abrupt client kill.
    public static let backgroundChildSurvivesAKill: ServerQuirkID = "SQ-008"
    /// `ClientAliveInterval` changes nothing about that.
    public static let clientAliveDoesNotReap: ServerQuirkID = "SQ-009"
    /// Tailscale SSH puts every session in `tailscaled`'s process group.
    public static let tailscaleSharesTheProcessGroup: ServerQuirkID = "SQ-010"
    /// A remote command killed by a signal makes `ssh` exit 255 with nothing on stderr.
    public static let signalKillIs255WithNoStderr: ServerQuirkID = "SQ-011"
    /// OpenSSH gives each session a process group of its own.
    public static let opensshGivesASessionItsOwnGroup: ServerQuirkID = "SQ-012"
    /// Writing over a running executable fails `ETXTBSY`.
    public static let etxtbsyOverARunningBinary: ServerQuirkID = "SQ-032"
    /// `mkdir`'s attributes go through the server's umask.
    public static let mkdirGoesThroughTheUmask: ServerQuirkID = "SQ-033"
    /// The wrapper's `EXIT` trap does not run when it is `SIGKILL`ed; the FIFO is left.
    public static let killedWrapperLeavesItsFIFO: ServerQuirkID = "SQ-069"
    /// A `kill -9` of the client leaves no helper on the server within 10 s.
    public static let helperDiesWithTheRelay: ServerQuirkID = "SQ-070"
    /// One static binary runs on both glibc and musl and self-reports the same digest.
    public static let oneStaticBinaryOnGlibcAndMusl: ServerQuirkID = "SQ-066"
    /// A server may have neither `sha256sum` nor `shasum`, and a hash the build embeds in
    /// a binary cannot be the hash of that binary: `--version` digests its own executable.
    public static let versionDigestsItsOwnExecutable: ServerQuirkID = "SQ-067"

    // MARK: shells and remote scripts

    /// A `ForceCommand internal-sftp` account may answer with a plain sentence.
    public static let forceCommandAnswersPlainText: ServerQuirkID = "SQ-013"
    /// An external `sftp-server` behind a noisy rc file corrupts the `VERSION` reply.
    public static let noisyRCBreaksTheExternalSFTPServer: ServerQuirkID = "SQ-014"
    /// rc files print on non-interactive startup, in every shell shape.
    public static let rcFilesPrintNonInteractively: ServerQuirkID = "SQ-015"
    /// An rc file can leave a background child holding stdout, so EOF never arrives.
    public static let backgroundChildHoldsStdout: ServerQuirkID = "SQ-016"
    /// Debian's `/bin/sh` is dash, which has no `read -t`.
    public static let debianShIsDash: ServerQuirkID = "SQ-017"
    /// dash answers `;;` with a syntax error and the channel dies.
    public static let dashRejectsDoubleSemicolon: ServerQuirkID = "SQ-018"
    /// `.` with no argument is a special builtin whose failure ends the shell.
    public static let dotIsASpecialBuiltin: ServerQuirkID = "SQ-019"
    /// `printf "\\0<sentinel>"` eats the octal digits after the NUL.
    public static let printfEatsTheSentinelsFirstBytes: ServerQuirkID = "SQ-020"
    /// Weird directory names work as sweep roots under the `set --` quoting rule.
    public static let weirdNamesSurviveTheQuotingRule: ServerQuirkID = "SQ-050"

    // MARK: SFTP

    /// Go `pkg/sftp` advertises exactly three extensions; that fingerprint identifies it.
    public static let goPkgSFTPAdvertisesThree: ServerQuirkID = "SQ-024"
    /// OpenSSH's own `sftp-server` advertises the eleven-name set.
    public static let opensshAdvertisesTheFullSet: ServerQuirkID = "SQ-025"
    /// Alpine's `internal-sftp` offers the same set as the external server.
    public static let internalSFTPMatchesTheExternal: ServerQuirkID = "SQ-026"
    /// `limits@openssh.com` sizes the request, not the window.
    public static let limitsSizesTheRequest: ServerQuirkID = "SQ-027"
    /// SFTP v3 carries nine status codes and no errno.
    public static let nineStatusCodesAndNoErrno: ServerQuirkID = "SQ-028"
    /// OpenSSH's `SSH2_FXP_SYMLINK` takes its two paths in the opposite order.
    public static let symlinkArgumentsAreReversed: ServerQuirkID = "SQ-029"
    /// SFTP `opendir` follows a symlink.
    public static let opendirFollowsASymlink: ServerQuirkID = "SQ-030"
    /// `readdir` carries attributes but no link target.
    public static let readdirCarriesNoLinkTarget: ServerQuirkID = "SQ-031"
    /// A plain `rename` may refuse an existing name or may overwrite it.
    public static let renameSemanticsVary: ServerQuirkID = "SQ-034"

    // MARK: the OpenSSH client

    /// `ssh` ends every stderr log line with CRLF.
    public static let stderrLinesEndCRLF: ServerQuirkID = "SQ-035"
    /// `remote software version` is printed only at DEBUG1 and above.
    public static let remoteVersionOnlyAtDebug1: ServerQuirkID = "SQ-036"
    /// A mux client never speaks to the server.
    public static let muxClientNeverSeesTheServer: ServerQuirkID = "SQ-037"
    /// `ProxyJump=none` written before `ProxyCommand` discards the ProxyCommand.
    public static let proxyJumpNoneBeforeProxyCommandWins: ServerQuirkID = "SQ-038"
    /// `ssh` percent-expands a `ProxyCommand` before `/bin/sh` sees it.
    public static let proxyCommandIsPercentExpanded: ServerQuirkID = "SQ-039"
    /// `ControlMaster=no` alone still attaches to the config's socket.
    public static let hopNeedsControlPathNone: ServerQuirkID = "SQ-040"
    /// With `ControlPersist` set, `ssh` forks away.
    public static let controlPersistForksAway: ServerQuirkID = "SQ-041"
    /// A mux client with no socket opens a second unsupervised connection.
    public static let muxClientNeedsBatchModeAndAFalseProxy: ServerQuirkID = "SQ-042"
    /// A restarted location can hold two masters, the second with no socket at all.
    public static let secondMasterRunsWithoutASocket: ServerQuirkID = "SQ-043"
    /// An unlinked socket cannot be reached by `-O exit` at all.
    public static let unlinkedSocketNeedsThePID: ServerQuirkID = "SQ-044"
    /// `$TMPDIR` is shared: a `sshdrive-*` name there is not necessarily ours, so every
    /// candidate for the orphan sweep is `lstat`ed for `S_IFSOCK`.
    public static let sweepCandidatesMustBeSockets: ServerQuirkID = "SQ-074"
    /// `pgrep` counts zombies, so liveness is read from the process **state**.
    public static let zombiesAreCountedByPgrep: ServerQuirkID = "SQ-075"
    /// The host-key question reaches askpass with `SSH_ASKPASS_PROMPT` unset.
    public static let hostKeyQuestionHasNoHint: ServerQuirkID = "SQ-047"
    /// `Enter passphrase for key '%.100s': ` truncates.
    public static let passphrasePromptTruncates: ServerQuirkID = "SQ-048"
    /// stderr distinguishes no key-agent state.
    public static let stderrHidesTheKeyAgentState: ServerQuirkID = "SQ-052"
    /// `MaxSessions 2` leaves exactly one spare channel.
    public static let maxSessionsTwoLeavesOneSpare: ServerQuirkID = "SQ-021"
    /// A channel is proved open only by completing the SFTP handshake on it.
    public static let aChannelIsProvedByItsHandshake: ServerQuirkID = "SQ-022"
    /// A channel open that failed because the master died is not a refusal.
    public static let aDeadMasterIsNotARefusal: ServerQuirkID = "SQ-079"

    // MARK: auth shapes

    /// The prompt strings are exact, trailing spaces included.
    public static let promptStringsAreExact: ServerQuirkID = "SQ-060"
    /// Tailscale SSH authenticates with the `none` method.
    public static let tailscaleAuthenticatesWithNone: ServerQuirkID = "SQ-061"
    /// A keyboard-interactive password reaches askpass as `(<user>@<host>) Password: `.
    public static let keyboardInteractivePromptShape: ServerQuirkID = "SQ-062"
    /// Two hops are told apart by the argv of the asking `ssh`, never by the prompt.
    public static let hopsAreToldApartByArgv: ServerQuirkID = "SQ-063"
    /// A server can accept both a key and a password for the same account.
    public static let keyAndPasswordTogether: ServerQuirkID = "SQ-064"

    // MARK: the box the tests run on

    /// APFS refuses a filename whose bytes are not valid UTF-8 (`mkdir` answers `EILSEQ`).
    public static let apfsRefusesNonUTF8Names: ServerQuirkID = "SQ-080"
    /// macOS's `/usr/bin/find` is BSD, not GNU findutils: `-cmin` yes, `-printf` no.
    public static let macOSFindIsBSD: ServerQuirkID = "SQ-081"
    /// XNU takes `p_comm` from the interpreter binary, and a copy of a system shell is
    /// killed by a launch constraint, so a script stub can never be named `ssh` there.
    public static let processNameComesFromTheInterpreter: ServerQuirkID = "SQ-082"
    /// `/etc/zshenv` runs `path_helper`, which rewrites `PATH` after `$ZDOTDIR/.zshenv`.
    public static let pathHelperRewritesTheZshPATH: ServerQuirkID = "SQ-083"
    /// A shell prints a job-status report when a foreground child dies by a signal, and
    /// dash writes it to the command's redirected stderr rather than to its own.
    public static let shellsReportASignalledChild: ServerQuirkID = "SQ-084"
    /// `PATH_MAX` is 1024 on macOS and `sun_path` holds 104 bytes.
    public static let hostPathLimits: ServerQuirkID = "SQ-085"
    /// A test child inherits an ignored `SIGINT` on Darwin and an ignored `SIGPIPE`
    /// everywhere, so neither of the two silent signals can kill a shell from a scenario.
    public static let inheritedIgnoredSignals: ServerQuirkID = "SQ-086"

    /// Every id above, in the order a reader of `docs/quirks/servers.md` meets it.
    public static let implemented: [ServerQuirkID] = [
        noBusyboxCmin, busyboxFindVersionExitsZero, noBusyboxPrintf, busyboxCminFailsTheSweep,
        mminMissesCtimeOnly, findTimeTestCostsAStat, findHasNoPortableDashDash,
        containersShareTheHostClock, nonUTF8RootCannotReachFind,
        backgroundChildSurvivesAKill, clientAliveDoesNotReap, tailscaleSharesTheProcessGroup,
        signalKillIs255WithNoStderr, opensshGivesASessionItsOwnGroup, etxtbsyOverARunningBinary,
        mkdirGoesThroughTheUmask, killedWrapperLeavesItsFIFO, helperDiesWithTheRelay,
        oneStaticBinaryOnGlibcAndMusl, versionDigestsItsOwnExecutable,
        forceCommandAnswersPlainText, noisyRCBreaksTheExternalSFTPServer,
        rcFilesPrintNonInteractively, backgroundChildHoldsStdout, debianShIsDash,
        dashRejectsDoubleSemicolon, dotIsASpecialBuiltin, printfEatsTheSentinelsFirstBytes,
        weirdNamesSurviveTheQuotingRule,
        goPkgSFTPAdvertisesThree, opensshAdvertisesTheFullSet, internalSFTPMatchesTheExternal,
        limitsSizesTheRequest, nineStatusCodesAndNoErrno, symlinkArgumentsAreReversed,
        opendirFollowsASymlink, readdirCarriesNoLinkTarget, renameSemanticsVary,
        stderrLinesEndCRLF, remoteVersionOnlyAtDebug1, muxClientNeverSeesTheServer,
        proxyJumpNoneBeforeProxyCommandWins, proxyCommandIsPercentExpanded,
        hopNeedsControlPathNone, controlPersistForksAway,
        muxClientNeedsBatchModeAndAFalseProxy, secondMasterRunsWithoutASocket,
        unlinkedSocketNeedsThePID, sweepCandidatesMustBeSockets, zombiesAreCountedByPgrep,
        hostKeyQuestionHasNoHint, passphrasePromptTruncates,
        stderrHidesTheKeyAgentState, maxSessionsTwoLeavesOneSpare,
        aChannelIsProvedByItsHandshake, aDeadMasterIsNotARefusal,
        promptStringsAreExact, tailscaleAuthenticatesWithNone, keyboardInteractivePromptShape,
        hopsAreToldApartByArgv, keyAndPasswordTogether,
        apfsRefusesNonUTF8Names, macOSFindIsBSD, processNameComesFromTheInterpreter,
        pathHelperRewritesTheZshPATH, shellsReportASignalledChild, hostPathLimits,
        inheritedIgnoredSignals,
    ]
}
