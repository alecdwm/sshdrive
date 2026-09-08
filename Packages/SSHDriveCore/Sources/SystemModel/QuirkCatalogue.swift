import Foundation

/// The rest of `docs/quirks/macos.md`, as the model reads it: writes and conflicts,
/// eviction and content policy, attributes and names, and the launchd/LaunchServices half.
///
/// Every row here is one entry of that file, and every one of them is read by a rule in
/// `SystemModel` that cites the same id. Where a behaviour was measured **once** or is an
/// inference from a single trace, the measurement's `source` says so in as many words and
/// the rule that reads it carries a `confidence:` comment - the model is allowed to be
/// uncertain, but not silently.
extension QuirkTable {

    // MARK: Writes, conflicts and saves

    static let writeQuirks: [Quirk] = [
        Quirk(
            id: .fetchErrorsAreReversible,
            statement:
                "From fetchContents, .noSuchItem and .cannotSynchronize both leave the item in "
                + "place and differ only in what the reader is told (ESTALE against ETIMEDOUT).",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-8; gotcha 62")
            ]),
        Quirk(
            id: .filenameCollisionRetriedForEver,
            statement:
                "A .filenameCollision from createItem is retried for ever with no alert, the "
                + "caller is told it succeeded, and the pending-items enumerator stays empty.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-4; gotcha 30")
            ]),
        Quirk(
            id: .filenameCollisionRetrySchedule,
            statement:
                "The collision backoff was measured at 0 s, 0.04 s, 5 s, 15 s and doubling from "
                + "there.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .durations([0, 0.04, 5, 15]),
                    source:
                        "results 2026-09-04 evening, s3-4 (one run; the model doubles the last "
                        + "interval past the fourth - confidence: measured to 15 s only)")
            ]),
        Quirk(
            id: .finderResolvesCollisionsItself,
            statement:
                "A real name collision inside Finder never reaches the provider: Finder renames "
                + "the duplicate itself (run.sh -> run copy.sh).",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-4")
            ]),
        Quirk(
            id: .pendingEditOnAGoneItemIsReOfferedAsACreate,
            statement:
                "A pending edit on an item the provider reports deleted is not lost: it is "
                + "re-offered as a createItem of the same name, which then collides for ever.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-7; DESIGN.md section 6.4's guard")
            ]),
        Quirk(
            id: .queuedWriteRetrySchedule,
            statement:
                "A queued write is re-offered for ever on a doubling backoff with no ceiling in "
                + "sight: 5.50, 10.56, 20.30, 43.03, 79.36, 153.23, 331.30 s and still climbing.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions,
                    value: .durations([5.50, 10.56, 20.30, 43.03, 79.36, 153.23, 331.30]),
                    source:
                        "results 2026-09-04 (M5) s5-1; gotcha 59 (ten minutes of one outage; the "
                        + "model doubles past the seventh - confidence: no ceiling was reached)")
            ]),
        Quirk(
            id: .noFetchRetry,
            statement:
                "The system never re-issues a failed fetchContents. One call, one error, and "
                + "nothing after it; a second read produces a second call.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-4; gotcha 59")
            ]),
        Quirk(
            id: .atomicSaveKeepsTheIdentifier,
            statement:
                "An atomic save arrives as one modifyItem on the original item (0x289 and 0xc1), "
                + "with no createItem and no deleteItem.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-8")
            ]),
        Quirk(
            id: .renameIsOneModifyItem,
            statement: "A Finder rename is one modifyItem with changedFields = 0x2 (.filename).",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(0x2),
                    source: "results 2026-09-04 evening, \"Also recorded\"")
            ]),
        Quirk(
            id: .chmodIsFileSystemFlags,
            statement:
                "chmod inside the mount arrives as modifyItem with changedFields = 0x100; a "
                + "chmod +x on an already-755 file produces no call at all.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(0x100),
                    source: "results 2026-09-04 evening, s3-5")
            ]),
        Quirk(
            id: .walkIsServedFromTheReplica,
            statement:
                "A readdir/lstat walk of the mount is answered from the system's replica and "
                + "reaches the extension not at all.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-9")
            ]),
        Quirk(
            id: .disconnectWorksFromTheExtension,
            statement:
                "disconnect(reason:) works from inside the extension: the domain goes "
                + "permanently disconnected, the replica listing and a queued write survive, and "
                + "re-launching the app lifts it.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M5) s5-5; gotcha 61")
            ]),
    ]

    // MARK: Eviction, content policy and pinning

    static let evictionQuirks: [Quirk] = [
        Quirk(
            id: .evictIsRecursive,
            statement:
                "evictItem evicts a directory recursively and works on .rootContainer: 11 "
                + "materialized items to 0 from one call.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-1")
            ]),
        Quirk(
            id: .evictAfterAModifyIsRefused,
            statement:
                "An evictItem issued straight after a modifyItem reply is refused -2008; the "
                + "same call seconds later succeeds and the first retry has always been enough.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source:
                        "results 2026-09-04 (M4) \"Three assumptions that failed\"; gotcha 49 "
                        + "(the window itself was never measured - confidence: the model refuses "
                        + "exactly the first call after a reply, which is what was seen)")
            ]),
        Quirk(
            id: .nonEvictableSaysNothingAboutWhy,
            statement:
                "-2008 is returned for both a pending upload and a kept item, so the eviction "
                + "loop cannot tell a pin from a pending write by error code.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-3, s6-5; gotcha 82")
            ]),
        Quirk(
            id: .parentOfAPendingItemFailsOpaquely,
            statement:
                "Evicting the parent directory of a pending item fails as NSCocoaErrorDomain "
                + "4101 with an underlying contentVersionMismatch, not -2006.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(4101),
                    source: "results 2026-09-04 s4-3")
            ]),
        Quirk(
            id: .evictionMovesAtime,
            statement: "An eviction moves atime, so a TTL loop must read atime before it evicts.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-1")
            ]),
        Quirk(
            id: .atimeIsAdvancedDeferred,
            statement:
                "Something in the system advances a materialized file's atime minutes after the "
                + "fetch, with no read of ours near it: a file fetched 280 s earlier had an "
                + "atime 23 s old.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(257),
                    source:
                        "results 2026-09-05 (M7/8) \"The assumption that failed: atime\"; gotcha "
                        + "80 (one file, one reading - confidence: the model schedules a single "
                        + "advance 257 s after the fetch, which is the one gap measured)")
            ]),
        Quirk(
            id: .atimeFollowsRelatime,
            statement:
                "atime follows the relatime rule on APFS and the write is deferred: a stat right "
                + "after materialization still shows the old value.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-2; results 2026-09-05 (M7/8)")
            ]),
        Quirk(
            id: .policyRefusesNotTheCapability,
            statement:
                "The item's effective contentPolicy, inherited from an eager ancestor, is what "
                + "refuses an eviction - not allowsEvicting.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-5; gotcha 23")
            ]),
        Quirk(
            id: .systemPutsAllowsEvictingBack,
            statement:
                "The system puts allowsEvicting back: the capability we serve is ignored and the "
                + "bit reported follows isDownloaded.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening s6-7; results 2026-09-04 late s6-7")
            ]),
        Quirk(
            id: .inheritedIsTheNeutralPolicy,
            statement:
                "contentPolicy = .inherited is the neutral value: an item served it forces "
                + "nothing and a freshly added domain fetches 0 items indefinitely.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-12")
            ]),
        Quirk(
            id: .explicitLazyBeatsAnEagerAncestor,
            statement:
                "An explicit .downloadLazily on a child overrides an eager ancestor: only the "
                + "direct sibling was fetched and the excluded subtree stayed dataless.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-6")
            ]),
        Quirk(
            id: .eagerPullsNeverEnumeratedSubfolders,
            statement:
                "An eager policy downloads a whole subtree including subfolders nothing has ever "
                + "listed: a folder with no index row at all was asked for and its eight files "
                + "came down in the same pass.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-1, s6-2")
            ]),
        Quirk(
            id: .ancestorsAreNotIngestedFromTheWorkingSet,
            statement:
                "Ancestors reported through the working set are not ingested; a lookup of the "
                + "path in the replica (getUserVisibleURL plus one lstat) is what starts it.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-3; gotcha 25 (reproduced three times)")
            ]),
        Quirk(
            id: .eagerOnTheRootDownloadsEverything,
            statement:
                "An eager policy on .rootContainer downloads the whole location - 20 items, "
                + "directories included. The root is not a special case.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s6-9")
            ]),
        Quirk(
            id: .concurrentFetchCeiling,
            statement:
                "The system holds at most six fetchContents calls open at once for an eager "
                + "subtree: strict batches of six, never seven, over 38 transfers.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(6),
                    source: "results 2026-09-04 s6-11")
            ]),
        Quirk(
            id: .foregroundOpensAreAllAdmitted,
            statement:
                "Eight files opened at once from a shell arrive as eight simultaneous foreground "
                + "fetchContents calls, so the six-fetch ceiling bounds an eager subtree only.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(8),
                    source: "results 2026-09-04 (M3 part 1); gotcha 42")
            ]),
        Quirk(
            id: .rootEvictFailsWholeWhileAnythingIsKept,
            statement:
                "evictItem on the root container fails as a whole while anything under it is "
                + "kept: the call meets a kept child and returns an error rather than evicting "
                + "the rest.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-05 (M7/8) \"Two smaller things\"; gotcha 82")
            ]),
        Quirk(
            id: .unpinSettleWindow,
            statement:
                "For 5-10 s after an unpin the system has not re-read the rows whose policy "
                + "changed and an eviction fails as NSCocoaErrorDomain \"The file couldn't be "
                + "opened\", naming no reason.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(10),
                    source:
                        "results 2026-09-05 (M7/8); gotcha 82 (\"5-10 s\" for a single file - "
                        + "confidence: the model takes the upper bound)")
            ]),
        Quirk(
            id: .unpinSettleWindowForTheRoot,
            statement:
                "The root container did not become evictable within a minute of the same unpin.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(60),
                    source:
                        "results 2026-09-05 (M7/8) (one observation, bounded below only - "
                        + "confidence: the model refuses the root for the whole minute measured)")
            ]),
    ]

    // MARK: Attributes, tags, names and the menu

    static let attributeQuirks: [Quirk] = [
        Quirk(
            id: .tagsArriveAsTagData,
            statement:
                "Finder tags arrive as the item's tagData and nothing else: one modifyItem with "
                + "changedFields = 0x10 and an empty extendedAttributes dictionary.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(0x10),
                    source: "results 2026-09-04 (M4) \"S10\"; results 2026-09-04 s4-4; gotchas 26, 51")
            ]),
        Quirk(
            id: .tagsAreWipedOnReDownload,
            statement:
                "Tags are wiped on the next re-download unless the item returns them; ordinary "
                + "xattrs survive.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-4")
            ]),
        Quirk(
            id: .aFrozenMetadataVersionStillEndsTheModify,
            statement:
                "A tagData modifyItem answered with the metadata version the item already had is "
                + "still asked only once: the xattr hash is not what stops a retry loop, because "
                + "there is no retry loop. The hash moves a version only for an agent-side change.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M4) \"S10\", debug fault --frozen-metadata on")
            ]),
        Quirk(
            id: .onlySyncableXattrsReachTheExtension,
            statement:
                "The system decides which xattrs the extension is told about: only the name "
                + "carrying XATTR_FLAG_SYNCABLE (the #S suffix) arrived; ordinary names, "
                + "com.apple.metadata:_kMDItemUserTags and com.apple.FinderInfo never do.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .text("#S"),
                    source: "results 2026-09-04 s4-4 (org.sshdrive.spike2#S arrived; org.sshdrive.spike did not)")
            ]),
        Quirk(
            id: .xattrsSurviveAnEviction,
            statement:
                "Extended attributes survive an eviction: the system sets them on dataless files "
                + "and preserves them, treating them as metadata rather than content.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 s4-4")
            ]),
        Quirk(
            id: .dsStoreNeverReachesTheExtension,
            statement:
                "A .DS_Store written into the mount never reaches the extension: no createItem, "
                + "no modifyItem, no row. The system keeps it in the replica and asks nobody to "
                + "upload it.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M4) \"Three assumptions that failed\"; gotcha 52")
            ]),
        Quirk(
            id: .displayNameIsTheBareNickname,
            statement:
                "displayName is the bare nickname: the mount directory is SSHDrive-<displayName> "
                + "and Finder's label is SSH Drive - <displayName>, so a nickname that repeats "
                + "the app name stutters.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 evening, s3-2; gotcha 28")
            ]),
        Quirk(
            id: .addDomainRenamesInPlace,
            statement:
                "add(domain) with an identifier the system already holds and a new displayName "
                + "renames the domain in place: the mount directory is renamed, the materialized "
                + "set and the pending upload are unchanged and nothing is re-fetched.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-05 (M10) \"S9\"")
            ]),
        Quirk(
            id: .addDomainMayReport4099AfterLanding,
            statement:
                "add(domain) can report NSCocoaErrorDomain 4099 after the call has landed.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(4099),
                    source: "results 2026-09-05 (M10), S9; gotcha 95")
            ]),
        Quirk(
            id: .finderEntriesFollowIsDownloaded,
            statement:
                "Finder's own File Provider entries are exactly two - Download Now when the item "
                + "is dataless, Remove Download when it is materialized - chosen by isDownloaded "
                + "and nothing else, and Remove Download is still offered on a kept item.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 late, s6-7 (screenshots); gotcha 32")
            ]),
        Quirk(
            id: .customActionsAreTopLevelOneOfAPair,
            statement:
                "Our custom actions are drawn at the very bottom of the contextual menu at the "
                + "top level, exactly one of a pair at a time, and on the window background "
                + "(evaluated against the folder being shown) but never on the sidebar row.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 late, s6-8, s6-10 (screenshots); gotcha 32")
            ]),
        Quirk(
            id: .activationRuleBindsFileproviderItems,
            statement:
                "A custom action's activation rule binds fileproviderItems, lower-case p, as a "
                + "key path; fileProviderItems and $fileproviderItems each drop the entry "
                + "silently with nothing in any log.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .text("fileproviderItems"),
                    source: "results 2026-09-04 evening, s6-8; gotcha 31")
            ]),
        Quirk(
            id: .decorationKeysAreTheBareFour,
            statement:
                "A decoration's Info.plist keys are the bare Identifier, BadgeImageType, Label "
                + "and Category, and BadgeImageType is a UTI conforming to "
                + "com.apple.icon-decoration.badge.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-05 (M7/8) \"Two smaller things\"; gotcha 81")
            ]),
        Quirk(
            id: .systemMakesRealSymlinksUnderCloudStorage,
            statement:
                "The system creates a real symlink under CloudStorage for an item served as one "
                + "(lrwx------, readlink returns the row's target), Finder gives it Kind \"Alias\" "
                + "and an arrow badge, and ln -s reaches createItem with the target intact.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M4) \"S8 - symlinks\"")
            ]),
        Quirk(
            id: .aDanglingSymlinkPresentsIdentically,
            statement:
                "A dangling symlink presents identically to a live one: same badge, same Kind, "
                + "size = the target string's length, no broken-link marker.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 (M4) \"S8 - symlinks\"")
            ]),
        Quirk(
            id: .aRefusedCreateSurfacesAsUploadingError,
            statement:
                "A refused ln -s is not a message the user sees: ln -s exits 0, the system keeps "
                + "the item locally, and the refusal comes back as its uploadingError (-2005).",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(-2005),
                    source: "results 2026-09-04 (M4) \"S8 - symlinks\"")
            ]),
    ]

    // MARK: The trash, launchd and LaunchServices

    static let lifecycleQuirks: [Quirk] = [
        Quirk(
            id: .supportsSyncingTrashDefaultsYes,
            statement:
                "NSFileProviderDomain.supportsSyncingTrash defaults to YES; not setting "
                + "allowsTrashing on items does not stop the system giving the domain a trash.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 \".Trash hang\"")
            ]),
        Quirk(
            id: .systemCreatesTheTrashNode,
            statement:
                "The system creates the trash node itself at add(domain) time, as a system-owned "
                + "item, and then asks the extension for its children.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 \".Trash hang\"")
            ]),
        Quirk(
            id: .noSuchItemOnTheTrashLoopsForEver,
            statement:
                "Answering enumerator(for: .trashContainer) with .noSuchItem makes the system "
                + "delete the trash from disk, fail, re-materialize it and ask again about once "
                + "a second, for ever; ls -la of the mount then never returns.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(1),
                    source: "results 2026-09-04 \".Trash hang\"; results 2026-09-04 S1 signed pass")
            ]),
        Quirk(
            id: .featureUnsupportedRetiresTheTrash,
            statement:
                "Answering NSCocoaErrorDomain / NSFeatureUnsupportedError makes the system "
                + "throttle, give up after two attempts and remove .Trash from the mount.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .int(2),
                    source: "results 2026-09-04 \".Trash hang\", \"Which half of the fix did the work\"")
            ]),
        Quirk(
            id: .quarantineBlocksPluginRegistration,
            statement:
                "LaunchServices registers no plugin of a quarantined bundle that no person has "
                + "launched: pluginkit -m prints nothing and fileproviderd answers FP -2001 / "
                + "-2014. xattr -dr then open -g is durable.",
            measurements: [
                QuirkMeasurement(
                    versions: [.v26_6], value: .bool(true),
                    source:
                        "results 2026-09-05 (M10) addendum; gotcha 99. A quarantined fresh-user "
                        + "install on 26.4 had passed, so the 26.4 column is deliberately the "
                        + "other value - confidence: which half of that difference matters is "
                        + "not claimed"),
                QuirkMeasurement(
                    versions: [.v26_4], value: .bool(false),
                    source: "results 2026-09-05 (M10) addendum: the 26.4 fresh-user install passed"),
            ]),
        Quirk(
            id: .registerDoesNotRepairAReplacedBundle,
            statement:
                "SMAppService.register() does not repair a registration whose bundle was deleted "
                + "and replaced: it keeps returning success while every spawn fails and retries "
                + "on a 10 s throttle for ever. Only unregister() followed by a launch clears it.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .bool(true),
                    source: "results 2026-09-04 S1 ad-hoc, f2")
            ]),
        Quirk(
            id: .unregisterReturnsBeforeLaunchdDrops,
            statement:
                "SMAppService.unregister() returns before launchd has dropped the job; a "
                + "register() inside that window leaves the job carrying the previous bundle's "
                + "launch constraint, dying on a 10 s retry for ever, with the mach service "
                + "accepting connections and answering nothing.",
            measurements: [
                QuirkMeasurement(
                    versions: bothVersions, value: .duration(10),
                    source:
                        "results 2026-09-05 (M10) \"The upgrade path\"; gotcha 93 (five seconds "
                        + "between the commands worked first time - confidence: the window "
                        + "itself was never measured, only bracketed)")
            ]),
    ]
}

extension QuirkID {
    // Writes, conflicts and saves
    public static let fetchErrorsAreReversible: QuirkID = "MQ-012"
    public static let filenameCollisionRetriedForEver: QuirkID = "MQ-014"
    public static let filenameCollisionRetrySchedule: QuirkID = "MQ-014.schedule"
    public static let finderResolvesCollisionsItself: QuirkID = "MQ-015"
    public static let queuedWriteRetrySchedule: QuirkID = "MQ-035"
    public static let noFetchRetry: QuirkID = "MQ-036"
    public static let walkIsServedFromTheReplica: QuirkID = "MQ-039"
    public static let disconnectWorksFromTheExtension: QuirkID = "MQ-040"
    public static let chmodIsFileSystemFlags: QuirkID = "MQ-047"
    public static let renameIsOneModifyItem: QuirkID = "MQ-048"
    public static let atomicSaveKeepsTheIdentifier: QuirkID = "MQ-049"
    /// New with this step: `s5-7`, which had no catalogue row of its own.
    public static let pendingEditOnAGoneItemIsReOfferedAsACreate: QuirkID = "MQ-080"

    // Eviction, content policy and pinning
    public static let evictAfterAModifyIsRefused: QuirkID = "MQ-017"
    public static let nonEvictableSaysNothingAboutWhy: QuirkID = "MQ-018"
    public static let parentOfAPendingItemFailsOpaquely: QuirkID = "MQ-019"
    public static let evictIsRecursive: QuirkID = "MQ-020"
    public static let evictionMovesAtime: QuirkID = "MQ-021"
    public static let atimeIsAdvancedDeferred: QuirkID = "MQ-022"
    public static let atimeFollowsRelatime: QuirkID = "MQ-023"
    public static let policyRefusesNotTheCapability: QuirkID = "MQ-024"
    public static let systemPutsAllowsEvictingBack: QuirkID = "MQ-025"
    public static let inheritedIsTheNeutralPolicy: QuirkID = "MQ-026"
    public static let explicitLazyBeatsAnEagerAncestor: QuirkID = "MQ-027"
    public static let eagerPullsNeverEnumeratedSubfolders: QuirkID = "MQ-028"
    public static let ancestorsAreNotIngestedFromTheWorkingSet: QuirkID = "MQ-029"
    public static let eagerOnTheRootDownloadsEverything: QuirkID = "MQ-030"
    public static let concurrentFetchCeiling: QuirkID = "MQ-031"
    public static let foregroundOpensAreAllAdmitted: QuirkID = "MQ-032"
    public static let rootEvictFailsWholeWhileAnythingIsKept: QuirkID = "MQ-033"
    public static let unpinSettleWindow: QuirkID = "MQ-034"
    public static let unpinSettleWindowForTheRoot: QuirkID = "MQ-034.root"

    // Attributes, tags, names and the menu
    public static let tagsArriveAsTagData: QuirkID = "MQ-042"
    public static let tagsAreWipedOnReDownload: QuirkID = "MQ-043"
    public static let onlySyncableXattrsReachTheExtension: QuirkID = "MQ-044"
    public static let xattrsSurviveAnEviction: QuirkID = "MQ-045"
    public static let dsStoreNeverReachesTheExtension: QuirkID = "MQ-046"
    public static let displayNameIsTheBareNickname: QuirkID = "MQ-050"
    public static let addDomainRenamesInPlace: QuirkID = "MQ-051"
    public static let addDomainMayReport4099AfterLanding: QuirkID = "MQ-052"
    public static let finderEntriesFollowIsDownloaded: QuirkID = "MQ-053"
    public static let customActionsAreTopLevelOneOfAPair: QuirkID = "MQ-054"
    public static let activationRuleBindsFileproviderItems: QuirkID = "MQ-055"
    public static let decorationKeysAreTheBareFour: QuirkID = "MQ-056"
    /// New with this step: S8's three symlink answers and S10's frozen-version one, none
    /// of which had a catalogue row.
    public static let systemMakesRealSymlinksUnderCloudStorage: QuirkID = "MQ-076"
    public static let aDanglingSymlinkPresentsIdentically: QuirkID = "MQ-077"
    public static let aRefusedCreateSurfacesAsUploadingError: QuirkID = "MQ-078"
    public static let aFrozenMetadataVersionStillEndsTheModify: QuirkID = "MQ-079"

    // The trash, launchd and LaunchServices
    public static let supportsSyncingTrashDefaultsYes: QuirkID = "MQ-008"
    public static let noSuchItemOnTheTrashLoopsForEver: QuirkID = "MQ-009"
    public static let featureUnsupportedRetiresTheTrash: QuirkID = "MQ-010"
    public static let quarantineBlocksPluginRegistration: QuirkID = "MQ-061"
    public static let registerDoesNotRepairAReplacedBundle: QuirkID = "MQ-062"
    public static let unregisterReturnsBeforeLaunchdDrops: QuirkID = "MQ-063"
    public static let systemCreatesTheTrashNode: QuirkID = "MQ-075"
}
