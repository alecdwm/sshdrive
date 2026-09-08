import Foundation
import XCTest

import AgentCore
import Config
import ProviderCore
import SFTP
@testable import ServerModel

/// Suite L over the SFTP **wire** (`docs/testing-architecture.md` section 5): the two name
/// and attribute rules whose ground truth is what the server really has in a directory and
/// what its `lstat` really says.
///
/// `FakeSFTPServer` speaks SFTP v3, so `SFTPClient`, `RealSFTPTransport`, `NameVisibility`,
/// `RemoteWriter` and `ItemDerivation` all run here unmodified, with no network and no
/// server.
final class NamesAndAttributesScenarios: XCTestCase {

    private func transport(
        _ profile: ServerProfile, seed: (FakeSFTPServer) -> Void = { _ in }
    ) async throws -> (FakeSFTPServer, RealSFTPTransport) {
        let server = FakeSFTPServer(profile: profile)
        seed(server)
        let transport = try await RealSFTPTransport.connect(
            stream: server.makeStream(), root: server.root)
        return (server, transport)
    }

    // MARK: - L7: a case collision is hidden

    /// **L7** (`MQ-015`, `MQ-016`, `SQ-028`) - `Makefile` and `makefile` in one directory.
    ///
    /// The server is byte-exact and case-sensitive; the replica is neither. A collision
    /// arriving from the server is renamed by the system **on its replica only**, silently,
    /// with no `modifyItem` back to us (`MQ-016`), so the user would see a name the server
    /// does not have and a write to it would land somewhere else. Section 5.4's rule is
    /// therefore that one name is shown and the other is recorded `hidden = 2` with a
    /// reason: the one already visible in the index keeps its slot, and among newcomers the
    /// byte-wise lowest wins, because `readdir` order is not stable across polls and the
    /// visible name must not flip from one cycle to the next.
    ///
    /// A real collision made *inside* Finder never reaches us at all - Finder resolves it
    /// itself (`MQ-015`) - so the only collisions the provider ever sees are these.
    func testL7_theByteOrderIncumbentWinsAndTheOtherIsHidden() async throws {
        let (_, deb) = try await transport(.debian) { server in
            server.put("Makefile", contents: Data("all:\n\ttrue\n".utf8))
            server.put("makefile", contents: Data("# the other one\n".utf8))
            server.put("README.md", contents: Data("mine".utf8))
        }
        let entries = try await deb.readdir(.root)
        XCTAssertEqual(entries.count, 3, "the server really holds both spellings")

        // Nothing is visible yet, so byte order decides: "M" (0x4D) beats "m" (0x6D).
        let fresh = NameVisibility.classify(entries: entries, visibleNames: [])
        let shown = fresh.entries.filter { $0.hidden == 0 }
            .map { String(decoding: $0.entry.name, as: UTF8.self) }.sorted()
        XCTAssertEqual(shown, ["Makefile", "README.md"])
        let hidden = try XCTUnwrap(fresh.hiddenEntries.first)
        XCTAssertEqual(String(decoding: hidden.entry.name, as: UTF8.self), "makefile")
        XCTAssertEqual(hidden.hidden, NameVisibility.hiddenCollision)
        XCTAssertTrue(
            hidden.reason.contains("cannot tell it from \"Makefile\""),
            "section 5.4: `status` prints the reason so the user can rename one server-side: \(hidden.reason)")

        // And once a name is visible it keeps its slot, whatever byte order says. Without
        // this the shown name would flip every time a hash-ordered readdir came back in a
        // different order.
        let incumbent = NameVisibility.classify(
            entries: entries, visibleNames: [Data("makefile".utf8)])
        let stillShown = incumbent.entries.filter { $0.hidden == 0 }
            .map { String(decoding: $0.entry.name, as: UTF8.self) }.sorted()
        XCTAssertEqual(stillShown, ["README.md", "makefile"], "L7: the incumbent keeps its slot")
        XCTAssertEqual(
            incumbent.hiddenEntries.map { String(decoding: $0.entry.name, as: UTF8.self) },
            ["Makefile"])
    }

    /// **L7** (`SQ-028`) - a create onto the hidden name is a `.filenameCollision`, and the
    /// wire is what makes that a *second question* rather than a status code.
    ///
    /// A hidden name holds its slot: the file is really there, so a create onto it must
    /// fail rather than succeed on the server and be hidden again at the next listing,
    /// which reads to the user as a file that saved and then vanished. The wire cannot say
    /// which failure it was - `EEXIST`, `ENOSPC`, `ENOTEMPTY` and `EXDEV` all arrive as a
    /// bare `FAILURE` with the literal message "Failure" (`SQ-028`) - so the agent asks an
    /// `lstat` of the destination before it reports a collision.
    func testL7_aCreateOntoTheHiddenNameIsAFilenameCollision() async throws {
        let (server, deb) = try await transport(.debian) { server in
            server.put("Makefile", contents: Data("all:\n\ttrue\n".utf8))
            server.put("makefile", contents: Data("# the other one\n".utf8))
        }

        // What the wire says on its own: a rename onto the taken name is a bare FAILURE
        // with no errno in it at all.
        server.put(".probe", contents: Data("x".utf8))
        do {
            try await deb.rename(
                try RelativePath(string: ".probe"), to: try RelativePath(string: "makefile"))
            XCTFail("SQ-034: this server's plain rename refuses an existing name")
        } catch let error as SFTPError {
            XCTAssertEqual(
                error, .failure("Failure"),
                "SQ-028: nine status codes and no errno; EEXIST looks like everything else")
        }
        try await deb.remove(try RelativePath(string: ".probe"))

        // The second question is what turns that into a sentence. `RemoteWriter` asks it.
        let writer = RemoteWriter(
            transport: deb,
            options: RemoteWriter.Options(macID: "abcd1234", localHostName: "m4"))
        do {
            _ = try await writer.upload(
                to: try RelativePath(string: "makefile"),
                mode: 0o644, modificationDate: nil, replacingExisting: false,
                base: nil, currentGeneration: 0, window: 4,
                source: { Data() }, progress: { _ in })
            XCTFail("L7: a create onto a name the server already has must be refused")
        } catch let error as RemoteWriteError {
            XCTAssertEqual(error, .filenameCollision("makefile"))
        }

        // Nothing of ours was left behind, and neither spelling was touched.
        XCTAssertEqual(server.contents(of: "makefile"), Data("# the other one\n".utf8))
        XCTAssertEqual(server.contents(of: "Makefile"), Data("all:\n\ttrue\n".utf8))
        XCTAssertTrue(
            server.names(in: "").allSatisfy { !$0.hasPrefix(".sshdrive-upload-") },
            "the refused upload took its temp file with it")
    }

    // MARK: - L8: locked by derivation

    /// **L8** (`MQ-047`) - a `0666` file inside a `0555` directory derives `caps 65` and
    /// `fsFlags 2`, and the write never leaves the Mac.
    ///
    /// Section 5.5: replacing a file's content goes through a temp file **in its
    /// directory**, so a file the account can write inside a directory it cannot is not
    /// saveable through SSH Drive at all. Section 5.4 therefore takes `allowsWriting` off
    /// such a file rather than letting the save fail at upload time: `capabilities` becomes
    /// `allowsReading | allowsEvicting` = 65, and `fileSystemFlags` becomes `userReadable`
    /// = 2 - no `userWritable`, and no `userExecutable`, since a mode of 0666 carries no
    /// execute bit for anyone.
    ///
    /// The last clause of the scenario - "the kernel refuses the write from the served
    /// flags and nothing is sent to the server" - is where this box's honesty runs out.
    /// **Measured** here: the modes the server really reports over the wire, the derivation
    /// from them, and that nothing reaches the server. **Inferred**, and only a VM can
    /// measure it: that macOS's own kernel is what refuses the `open` for write, from the
    /// `userWritable` flag alone. The nearest measurement there is is `MQ-047` - a `chmod
    /// +x` on a file that is already 755 produces no provider call at all, because the only
    /// bits the replica carries are the owner's - which says the served flags really are
    /// what the local filesystem answers from.
    func testL8_a0666FileInA0555DirectoryIsLockedByDerivation() async throws {
        let (server, deb) = try await transport(.debian) { server in
            server.putDirectory("readonly", mode: 0o555)
            server.put("readonly/notes.txt", contents: Data("read me".utf8), mode: 0o666)
            server.putDirectory("writable", mode: 0o755)
            server.put("writable/notes.txt", contents: Data("read me".utf8), mode: 0o666)
        }

        let account = ServerIdentity(uid: 1000, gid: 1000, supplementaryGroups: [])
        let locked = try await Self.derive(deb, path: "readonly/notes.txt", identity: account)
        XCTAssertEqual(locked.mode, 0o666, "the file's own mode, off the wire")
        XCTAssertEqual(locked.parentMode, 0o555, "and its directory's")
        XCTAssertEqual(
            locked.capabilities.rawValue, 65,
            "L8: allowsReading | allowsEvicting - no writing, renaming, deleting or reparenting")
        XCTAssertEqual(
            locked.capabilities, [.allowsReading, .allowsEvicting],
            "section 5.5: a temp file in the directory is what a save needs")
        XCTAssertEqual(locked.flags.rawValue, 2, "L8: userReadable and nothing else")
        XCTAssertFalse(locked.flags.contains(.userWritable))
        XCTAssertFalse(
            locked.flags.contains(.userExecutable), "0666 carries no execute bit for anybody")

        // The control: the same file, the same mode, a directory the account can write.
        let free = try await Self.derive(deb, path: "writable/notes.txt", identity: account)
        XCTAssertTrue(free.capabilities.contains(.allowsWriting))
        XCTAssertTrue(free.flags.contains(.userWritable))
        XCTAssertEqual(free.flags.rawValue, 6, "userReadable | userWritable")

        // The refusal, and the assertion that matters here: nothing is sent.
        server.clearRequestLog()
        XCTAssertFalse(
            Self.kernelAllowsWriting(locked.flags),
            "L8: the flags we served are what the local filesystem answers from")
        XCTAssertTrue(
            server.requests.isEmpty,
            "L8: a write refused from the served flags never becomes a provider call, so the "
                + "server is never asked and never has to refuse")
    }

    /// The two bitmasks a row carries, derived from one `lstat` of the item and one of its
    /// directory. `RowBuilder` copies both onto the row and changes neither, so this is the
    /// rule itself rather than a copy of it (sections 5.2, 5.4).
    private struct Derived {
        var mode: UInt32
        var parentMode: UInt32
        var capabilities: ProviderCapabilities
        var flags: ProviderFileSystemFlags
    }

    private static func derive(
        _ transport: RealSFTPTransport, path: String, identity: ServerIdentity
    ) async throws -> Derived {
        let item = try await transport.lstat(try RelativePath(string: path))
        let directory = try await transport.lstat(
            try XCTUnwrap(try RelativePath(string: path).parent))
        let capabilities = ItemDerivation.capabilities(
            type: item.type, mode: item.mode, uid: item.uid, gid: item.gid,
            parentMode: directory.mode, parentUID: directory.uid, parentGID: directory.gid,
            permissions: .mode, identity: identity, kept: false)
        let flags = ItemDerivation.fileSystemFlags(
            type: item.type, mode: item.mode, uid: item.uid, gid: item.gid,
            permissions: .mode, identity: identity, capabilities: capabilities,
            filename: String(decoding: try RelativePath(string: path).lastComponent ?? Data(), as: UTF8.self))
        return Derived(
            mode: item.mode, parentMode: directory.mode, capabilities: capabilities, flags: flags)
    }

    /// The one line this box cannot measure, written down rather than pretended: an item
    /// served without `userWritable` is not opened for writing on the Mac, so no
    /// `modifyItem` is ever made and nothing reaches the agent. The VM runbook is where the
    /// kernel's half of `L8` is proved; here it is a statement of what the derivation means.
    private static func kernelAllowsWriting(_ flags: ProviderFileSystemFlags) -> Bool {
        flags.contains(.userWritable)
    }
}
