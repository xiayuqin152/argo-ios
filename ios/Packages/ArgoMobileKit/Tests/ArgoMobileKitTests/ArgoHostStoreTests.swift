import XCTest
@testable import ArgoMobileKit

final class ArgoHostStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("argo-hosts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func store(tokens: InMemoryDeviceTokens, pairer: @escaping ArgoHostStore.Pairer) -> ArgoHostStore {
        ArgoHostStore(fileURL: dir.appendingPathComponent("hosts.json"), tokens: tokens, pairer: pairer)
    }

    func testPairSavesHostAndTokenSeparately() async throws {
        let tokens = InMemoryDeviceTokens()
        let seen = LockedBox<(PairingCode, String)?>(nil)
        let s = store(tokens: tokens) { code, name in
            seen.set((code, name))
            return GatewayCredential(device: "dev123", token: Fixture.token)
        }
        let none = try await s.hosts()
        XCTAssertEqual(none, [])
        let host = try await s.pair(code: "$ argo pair\n" + Fixture.code(), deviceName: "Yuqin 的 iPhone")
        XCTAssertEqual(seen.value?.0.secret, Fixture.secret)
        XCTAssertEqual(seen.value?.1, "Yuqin 的 iPhone")
        XCTAssertEqual(host.address, "10.0.0.5")
        XCTAssertEqual(host.gatewayPort, 6779)
        XCTAssertEqual(host.fingerprintData, Fixture.fingerprint)
        XCTAssertEqual(host.deviceID, "dev123")
        XCTAssertEqual(host.name, "10.0.0.5")
        XCTAssertEqual(try tokens.read(host.id), Fixture.token)

        let file = try String(contentsOf: dir.appendingPathComponent("hosts.json"), encoding: .utf8)
        XCTAssertFalse(file.contains(Fixture.token), "the token stays out of the hosts file")
        XCTAssertFalse(file.contains(Fixture.secret))

        let reopened = store(tokens: tokens) { _, _ in XCTFail("no pairing"); throw CancellationError() }
        let saved = try await reopened.hosts()
        XCTAssertEqual(saved, [host])
        let credential = try await reopened.credential(for: host)
        XCTAssertEqual(credential, GatewayCredential(device: "dev123", token: Fixture.token))
        let outcome = await reopened.launchOutcome(for: host)
        XCTAssertEqual(outcome, .connect)
    }

    func testRepairSameAddressKeepsIdentity() async throws {
        let tokens = InMemoryDeviceTokens()
        let n = LockedBox(0)
        let s = store(tokens: tokens) { _, _ in
            n.set(n.value + 1)
            return GatewayCredential(device: "dev\(n.value)", token: String(repeating: "\(n.value)", count: 40))
        }
        let first = try await s.pair(code: Fixture.code(), deviceName: "p", name: "Box")
        let again = try await s.pair(code: Fixture.code(), deviceName: "p")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(again.name, "Box")
        XCTAssertEqual(again.deviceID, "dev2")
        XCTAssertEqual(try tokens.read(first.id), String(repeating: "2", count: 40))
        let other = try await s.pair(code: Fixture.code(port: 7000), deviceName: "p")
        XCTAssertNotEqual(other.id, first.id)
        let count = try await s.hosts().count
        XCTAssertEqual(count, 2)
    }

    func testRepairDNSCaseKeepsIdentity() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        let first = try await s.pair(code: Fixture.code(host: "DevBox.Example"), deviceName: "p")
        let same = try await s.pair(code: Fixture.code(host: "devbox.example"), deviceName: "p")
        XCTAssertEqual(same.id, first.id)
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [first])
    }

    func testRepairInternationalizedDNSKeepsALabelIdentity() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        let first = try await s.pair(code: Fixture.code(host: "例子.测试"), deviceName: "p")
        let same = try await s.pair(code: Fixture.code(host: "XN--FSQU00A.XN--0ZWM56D"), deviceName: "p")
        XCTAssertEqual(same.id, first.id)
        XCTAssertEqual(same.address, "xn--fsqu00a.xn--0zwm56d")
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [first])
    }

    func testRepairIPv6AddressCaseKeepsIdentityOnlyOutsideZone() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        let first = try await s.pair(code: Fixture.code(host: "[FE80::1%en0]"), deviceName: "p")
        let same = try await s.pair(code: Fixture.code(host: "[fe80::1%en0]"), deviceName: "p")
        XCTAssertEqual(same.id, first.id)
        let otherZone = try await s.pair(code: Fixture.code(host: "[fe80::1%EN0]"), deviceName: "p")
        XCTAssertNotEqual(otherZone.id, first.id)
        XCTAssertEqual(otherZone.address, "fe80::1%EN0")
        let saved = try await s.hosts()
        XCTAssertEqual(saved.count, 2)
    }

    func testRawIPv6ZonesKeepSeparateCredentialsAcrossRepeatedSavesAndReopens() async throws {
        let tokens = InMemoryDeviceTokens()
        let zones = ["en0", "25en0", "25", "2525en0", "2525", "EN0"]
        let pairer: ArgoHostStore.Pairer = { code, _ in
            let index = zones.firstIndex { code.host == "fe80::1%\($0)" }! + 1
            return GatewayCredential(device: "dev\(index)", token: String(repeating: "\(index)", count: 40))
        }
        var identities: [String: UUID] = [:]
        for _ in 0..<3 {
            let reopened = store(tokens: tokens, pairer: pairer)
            for (index, zone) in zones.enumerated() {
                let address = "fe80::1%\(zone)"
                let saved = try await reopened.pair(code: Fixture.code(host: "[\(address)]"), deviceName: "p")
                XCTAssertEqual(saved.address, address)
                if let id = identities[zone] { XCTAssertEqual(saved.id, id) }
                identities[zone] = saved.id
                let credential = try await reopened.credential(for: saved)
                XCTAssertEqual(credential.device, "dev\(index + 1)")
                XCTAssertEqual(credential.token, String(repeating: "\(index + 1)", count: 40))
            }
            let saved = try await reopened.hosts()
            XCTAssertEqual(saved.count, zones.count)
            XCTAssertEqual(Set(saved.map(\.id)).count, zones.count)
        }
        let reopened = store(tokens: tokens) { _, _ in XCTFail("no pairing on load"); throw CancellationError() }
        let saved = try await reopened.hosts()
        XCTAssertEqual(Set(saved.map(\.address)), Set(zones.map { "fe80::1%\($0)" }))
        XCTAssertEqual(Set(saved.map(\.id)), Set(identities.values))
    }

    func testUnicodeCaseAndALabelRepairKeepIdentity() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        let first = try await s.pair(code: Fixture.code(host: "FAẞ.de"), deviceName: "p")
        for input in ["faß.de", "xn--fa-hia.de", "XN--FA-HIA.DE", "ＦＡẞ.de"] {
            let same = try await s.pair(code: Fixture.code(host: input), deviceName: "p")
            XCTAssertEqual(same.id, first.id)
        }
        let other = try await s.pair(code: Fixture.code(host: "fass.de"), deviceName: "p")
        XCTAssertNotEqual(first.id, other.id)
    }

    func testPairingErrorsSaveNothing() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in throw GatewayError.pairingRejected("used") }
        do {
            _ = try await s.pair(code: Fixture.code(), deviceName: "p")
            XCTFail("expected rejection")
        } catch let error as GatewayError {
            XCTAssertEqual(error, .pairingRejected("used"))
        }
        let afterReject = try await s.hosts()
        XCTAssertEqual(afterReject, [])
        do {
            _ = try await s.pair(code: "no code here", deviceName: "p")
            XCTFail("expected parse error")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .refusedLocally(.message("Invalid pairing code. Copy the complete code printed by argo pair on the host.")))
        }
        let bad = store(tokens: tokens) { _, _ in GatewayCredential(device: "d", token: "short") }
        do {
            _ = try await bad.pair(code: Fixture.code(), deviceName: "p")
            XCTFail("expected credential refusal")
        } catch is GatewayError {}
        let afterBad = try await bad.hosts()
        XCTAssertEqual(afterBad, [])
    }

    func testRemoveDeletesTokenAndRenameChecksNames() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        let a = try await s.pair(code: Fixture.code(), deviceName: "p", name: "A")
        let b = try await s.pair(code: Fixture.code(port: 7000), deviceName: "p", name: "B")
        do {
            _ = try await s.rename(b.id, to: " a ")
            XCTFail("expected clash")
        } catch is LoomError {}
        let renamed = try await s.rename(b.id, to: "C")
        XCTAssertEqual(renamed.name, "C")
        try await s.remove(a.id)
        XCTAssertNil(try tokens.read(a.id))
        let left = try await s.hosts().map(\.id)
        XCTAssertEqual(left, [b.id])
        do {
            _ = try await s.credential(for: a)
            XCTFail("expected needsPairing")
        } catch let error as ArgoClientError {
            guard case .needsPairing = error else { return XCTFail("\(error)") }
        }
        let outcome = await s.launchOutcome(for: a)
        if case .needsPairing = outcome {} else { XCTFail("expected needsPairing outcome") }
    }

    func testOldHostCannotReadTheCredentialOfANewPairing() async throws {
        let tokens = InMemoryDeviceTokens()
        let n = LockedBox(0)
        let s = store(tokens: tokens) { _, _ in
            n.set(n.value + 1)
            return GatewayCredential(device: "device\(n.value)", token: String(repeating: "\(n.value)", count: 40))
        }
        let old = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let current = try await s.pair(code: Fixture.code(), deviceName: "phone")
        do {
            _ = try await s.credential(for: old)
            XCTFail("old pin/device must never be combined with a new token")
        } catch let error as ArgoClientError {
            guard case .needsPairing = error else { return XCTFail("\(error)") }
        }
        let credential = try await s.credential(for: current)
        XCTAssertEqual(credential.device, "device2")
    }

    func testCancelledPairingDoesNotSaveANewHost() async throws {
        let tokens = InMemoryDeviceTokens()
        let s = store(tokens: tokens) { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return GatewayCredential(device: "device", token: Fixture.token)
        }
        let task = Task { try await s.pair(code: Fixture.code(), deviceName: "phone") }
        do {
            _ = try await task.value
            XCTFail("cancelled pairing must leave local storage unchanged")
        } catch is CancellationError {}
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [])
    }

    func testFailedRepairRestoresThePreviousToken() async throws {
        let memory = InMemoryDeviceTokens()
        let tokens = InterceptingDeviceTokens(memory: memory)
        let fileURL = dir.appendingPathComponent("state/hosts.json")
        let n = LockedBox(0)
        let s = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in
            n.set(n.value + 1)
            return GatewayCredential(device: "device\(n.value)", token: String(repeating: "\(n.value)", count: 40))
        }
        let old = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let originalFile = try Data(contentsOf: fileURL)
        let state = fileURL.deletingLastPathComponent()
        let preserved = dir.appendingPathComponent("preserved")
        tokens.afterSave = {
            try FileManager.default.moveItem(at: state, to: preserved)
            try Data("blocks directory creation".utf8).write(to: state)
        }
        let changedPinCode = Fixture.code().replacingOccurrences(of: Base64URL.encode(Fixture.fingerprint),
                            with: Base64URL.encode(Data(repeating: 9, count: 32)))
        do {
            _ = try await s.pair(code: changedPinCode, deviceName: "phone")
            XCTFail("expected host metadata write failure")
        } catch {}
        XCTAssertEqual(try memory.read(old.id), String(repeating: "1", count: 40))
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: preserved, to: state)
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [old])
        XCTAssertEqual(try Data(contentsOf: fileURL), originalFile)
        let usable = try await s.credential(for: old)
        XCTAssertEqual(usable.device, "device1")
        XCTAssertEqual(usable.token, String(repeating: "1", count: 40))
        XCTAssertEqual(old.fingerprintData, Fixture.fingerprint)
    }

    func testRepairRollbackFailureIsReported() async throws {
        let memory = InMemoryDeviceTokens()
        let tokens = InterceptingDeviceTokens(memory: memory)
        let fileURL = dir.appendingPathComponent("state/hosts.json")
        let s = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let state = fileURL.deletingLastPathComponent()
        let preserved = dir.appendingPathComponent("preserved")
        tokens.afterSave = {
            try FileManager.default.moveItem(at: state, to: preserved)
            try Data("blocks directory creation".utf8).write(to: state)
            tokens.saveError = LoomError.message("injected rollback token failure")
        }
        do {
            _ = try await s.pair(code: Fixture.code(), deviceName: "phone")
            XCTFail("expected metadata and rollback failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("injected rollback token failure"))
            XCTAssertTrue(error.localizedDescription.contains("重新配对"))
        }
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: preserved, to: state)
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [host])
    }

    func testCorruptFileIsReportedAndLeftAlone() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hosts.json")
        try Data("{not json".utf8).write(to: url)
        let s = store(tokens: InMemoryDeviceTokens()) { _, _ in GatewayCredential(device: "dev", token: Fixture.token) }
        do {
            _ = try await s.hosts()
            XCTFail("expected corrupt error")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(key, "The saved host store is corrupted: %@. Delete it and pair again.")
            XCTAssertEqual(arguments, [url.path])
        }
        do {
            _ = try await s.pair(code: Fixture.code(), deviceName: "p")
            XCTFail("pairing must not overwrite a corrupt file")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(key, "The saved host store is corrupted: %@. Delete it and pair again.")
            XCTAssertEqual(arguments, [url.path])
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("{not json".utf8))
    }

    func testRemoveMetadataFailureDoesNotDeleteCredential() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let fileURL = dir.appendingPathComponent("hosts.json")
        let s = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let original = try Data(contentsOf: fileURL)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        #if os(Linux)
        let readOnly = URL(fileURLWithPath: "/proc/self/fd/\(handle.fileDescriptor)")
        #else
        let readOnly = URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
        #endif
        let failing = ArgoHostStore(fileURL: readOnly, tokens: tokens) { _, _ in throw CancellationError() }
        do {
            try await failing.remove(host.id)
            XCTFail("expected atomic metadata write failure")
        } catch is CocoaError {}
        XCTAssertEqual(tokens.deletions, [])
        XCTAssertEqual(try tokens.read(host.id), Fixture.token)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let credential = try await s.credential(for: host)
        XCTAssertEqual(credential.device, host.deviceID)
    }

    func testRemoveCredentialFailureRestoresHostAndAllowsRetry() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let fileURL = dir.appendingPathComponent("hosts.json")
        let s = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let original = try Data(contentsOf: fileURL)
        tokens.deleteError = NSError(domain: NSOSStatusErrorDomain, code: -25308,
                                     userInfo: [NSLocalizedDescriptionKey: "injected deletion failure (OSStatus -25308)"])
        do {
            try await s.remove(host.id)
            XCTFail("credential deletion failure must reach the caller")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
            XCTAssertEqual((error as NSError).code, -25308)
        }
        let saved = try await s.hosts()
        XCTAssertEqual(saved, [host])
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let usable = try await s.credential(for: host)
        XCTAssertEqual(usable, GatewayCredential(device: host.deviceID, token: Fixture.token))
        tokens.deleteError = nil
        try await s.remove(host.id)
        let after = try await s.hosts()
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(try tokens.read(host.id))
        try await s.remove(host.id)
        XCTAssertEqual(tokens.deletions, [host.id, host.id], "an absent, unclaimed id must not authorize a Keychain deletion")
    }

    func testRemoveReportsCredentialAndMetadataRestoreFailuresAndCanRetry() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let fileURL = dir.appendingPathComponent("state/hosts.json")
        let s = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let state = fileURL.deletingLastPathComponent()
        let preserved = dir.appendingPathComponent("preserved")
        tokens.deleteError = NSError(domain: NSOSStatusErrorDomain, code: -25308,
                                     userInfo: [NSLocalizedDescriptionKey: "injected deletion failure (OSStatus -25308)"])
        tokens.beforeDelete = {
            try FileManager.default.moveItem(at: state, to: preserved)
            try Data("blocks metadata restoration".utf8).write(to: state)
        }
        do {
            try await s.remove(host.id)
            XCTFail("both failures must reach the caller")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(key.contains("Restoring the saved host also failed"))
            XCTAssertTrue(key.contains("Try Forget Host again"))
            XCTAssertEqual(arguments.count, 2)
            XCTAssertTrue(arguments[0].contains("OSStatus -25308"))
            XCTAssertFalse(arguments[1].isEmpty)
        }
        XCTAssertEqual(try tokens.read(host.id), Fixture.token)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: preserved, to: state)
        let reopened = ArgoHostStore(fileURL: fileURL, tokens: tokens) { _, _ in throw CancellationError() }
        do {
            _ = try await reopened.hosts()
            XCTFail("a recorded cleanup failure must reach the retry UI on reopening")
        } catch {
            XCTAssertEqual((error as NSError).code, -25308)
        }
        tokens.deleteError = nil
        let after = try await reopened.hosts()
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(try tokens.read(host.id), "the durable intent must recover without the previous process's host id")
        try await s.remove(host.id)
    }

    func testNewPairMetadataFailureCleansCredential() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = dir.appendingPathComponent("state")
        let s = ArgoHostStore(fileURL: state.appendingPathComponent("hosts.json"), tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let preserved = dir.appendingPathComponent("preserved")
        tokens.afterSave = {
            try FileManager.default.moveItem(at: state, to: preserved)
            try Data("blocks host metadata commit after the ownership record".utf8).write(to: state)
        }
        do {
            _ = try await s.pair(code: Fixture.code(), deviceName: "phone")
            XCTFail("expected metadata write failure")
        } catch is CocoaError {}
        let savedID = try XCTUnwrap(tokens.savedID)
        XCTAssertEqual(tokens.deletions, [savedID])
        XCTAssertNil(try tokens.read(savedID))
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: preserved, to: state)
        let loaded = try await s.hosts()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testNewPairReportsMetadataAndCredentialCleanupFailures() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = dir.appendingPathComponent("state")
        let calls = LockedBox(0)
        let s = ArgoHostStore(fileURL: state.appendingPathComponent("hosts.json"), tokens: tokens) { _, _ in
            calls.set(calls.value + 1)
            return GatewayCredential(device: "device", token: Fixture.token)
        }
        let preserved = dir.appendingPathComponent("preserved")
        tokens.afterSave = {
            try FileManager.default.moveItem(at: state, to: preserved)
            try Data("blocks host metadata commit after the ownership record".utf8).write(to: state)
        }
        tokens.deleteError = NSError(domain: NSOSStatusErrorDomain, code: -25308,
                                     userInfo: [NSLocalizedDescriptionKey: "injected cleanup failure (OSStatus -25308)"])
        do {
            _ = try await s.pair(code: Fixture.code(), deviceName: "phone")
            XCTFail("metadata and cleanup failures must be reported together")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(key.contains("Could not save the host"))
            XCTAssertTrue(key.contains("Removing its new device credential also failed"))
            XCTAssertEqual(arguments.count, 2)
            XCTAssertFalse(arguments[0].isEmpty)
            XCTAssertTrue(arguments[1].contains("OSStatus -25308"))
        }
        let savedID = try XCTUnwrap(tokens.savedID)
        XCTAssertEqual(try tokens.read(savedID), Fixture.token)
        XCTAssertEqual(tokens.deletions, [savedID])
        XCTAssertEqual(calls.value, 1, "cleanup failure must not re-pair automatically")
        try FileManager.default.removeItem(at: state)
        try FileManager.default.moveItem(at: preserved, to: state)
        let reopened = ArgoHostStore(fileURL: state.appendingPathComponent("hosts.json"), tokens: tokens) { _, _ in
            XCTFail("recovery must not pair again")
            throw CancellationError()
        }
        do {
            _ = try await reopened.hosts()
            XCTFail("the new account intent must preserve cleanup errors for retry")
        } catch { XCTAssertEqual((error as NSError).code, -25308) }
        tokens.deleteError = nil
        let after = try await reopened.hosts()
        XCTAssertTrue(after.isEmpty)
        XCTAssertNil(try tokens.read(savedID))
        XCTAssertEqual(calls.value, 1)
    }

    func testUnclaimedAccountsAndUnknownRemoveAreLeftAlone() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let unclaimed = UUID()
        try tokens.memory.save(Fixture.token, for: unclaimed)
        let file = dir.appendingPathComponent("hosts.json")
        let s = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let empty = try await s.hosts()
        XCTAssertTrue(empty.isEmpty)
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        try await s.remove(unclaimed)
        let loaded = try await s.hosts()
        XCTAssertEqual(loaded, [host])
        XCTAssertEqual(try tokens.read(unclaimed), Fixture.token)
        XCTAssertTrue(tokens.deletions.isEmpty)
    }

    func testNewPairOwnershipWriteFailureDoesNotTouchCredentials() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let file = dir.appendingPathComponent("hosts.json")
        let s = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        let original = try Data(contentsOf: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #if os(Linux)
        let readOnly = URL(fileURLWithPath: "/proc/self/fd/\(handle.fileDescriptor)")
        #else
        let readOnly = URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
        #endif
        let failing = ArgoHostStore(fileURL: readOnly, tokens: tokens) { _, _ in
            GatewayCredential(device: "new-device", token: String(repeating: "n", count: 43))
        }
        do {
            _ = try await failing.pair(code: Fixture.code(port: 7000), deviceName: "phone")
            XCTFail("ownership must be durable before saving a new token")
        } catch is CocoaError {}
        XCTAssertEqual(tokens.savedID, host.id)
        XCTAssertTrue(tokens.deletions.isEmpty)
        XCTAssertEqual(try tokens.read(host.id), Fixture.token)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnreadableOrMalformedOwnershipRecordNeverDeletesTokens() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let unclaimed = UUID()
        try tokens.memory.save(Fixture.token, for: unclaimed)
        let file = dir.appendingPathComponent("hosts.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let s = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in throw CancellationError() }
        do {
            _ = try await s.hosts()
            XCTFail("unreadable metadata must not become an empty store")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(key, "Could not read the saved host store: %@")
            XCTAssertEqual(arguments.count, 1)
            XCTAssertTrue(arguments[0].hasPrefix("hosts.json: "))
        }
        try FileManager.default.removeItem(at: file)
        let malformed = Data("{\"version\":1,\"hosts\":[],\"pendingCredentialCleanup\":\"invalid\"}".utf8)
        try malformed.write(to: file)
        do {
            _ = try await s.hosts()
            XCTFail("invalid ownership must fail without cleanup")
        } catch let error as ArgoClientError {
            guard case .invalidResponse(.message(let key, let arguments)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(key, "The saved host store is corrupted: %@. Delete it and pair again.")
            XCTAssertEqual(arguments, [file.path])
        }
        XCTAssertTrue(tokens.deletions.isEmpty)
        XCTAssertEqual(try tokens.read(unclaimed), Fixture.token)
        XCTAssertEqual(try Data(contentsOf: file), malformed)
    }

    func testRecoveryRetainsAnAlreadyCommittedHostAndItsToken() async throws {
        let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
        let file = dir.appendingPathComponent("hosts.json")
        let s = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in
            GatewayCredential(device: "device", token: Fixture.token)
        }
        let host = try await s.pair(code: Fixture.code(), deviceName: "phone")
        struct Interrupted: Encodable {
            let version = 1
            let hosts: [LoomHost]
            let pendingCredentialCleanup: [UUID]
        }
        try JSONEncoder().encode(Interrupted(hosts: [host], pendingCredentialCleanup: [host.id])).write(to: file)
        let loaded = try await s.hosts()
        XCTAssertEqual(loaded, [host])
        XCTAssertTrue(tokens.deletions.isEmpty)
        XCTAssertEqual(try tokens.read(host.id), Fixture.token)
        let credential = try await s.credential(for: host)
        XCTAssertEqual(credential.device, host.deviceID)
    }

    func testCleanupRecordWriteFailureIsReportedAndRetried() async throws {
        for removeHost in [false, true] {
            let tokens = InterceptingDeviceTokens(memory: InMemoryDeviceTokens())
            let parent = dir.appendingPathComponent(removeHost ? "forget" : "recover")
            let state = parent.appendingPathComponent("state")
            let preserved = parent.appendingPathComponent("preserved")
            let file = state.appendingPathComponent("hosts.json")
            let s = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in
                GatewayCredential(device: "device", token: Fixture.token)
            }
            let id: UUID
            if removeHost {
                id = try await s.pair(code: Fixture.code(), deviceName: "phone").id
            } else {
                id = UUID()
                try tokens.memory.save(Fixture.token, for: id)
                try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
                struct Pending: Encodable {
                    let version = 1
                    let hosts: [LoomHost] = []
                    let pendingCredentialCleanup: [UUID]
                }
                try JSONEncoder().encode(Pending(pendingCredentialCleanup: [id])).write(to: file)
            }
            tokens.beforeDelete = {
                try FileManager.default.moveItem(at: state, to: preserved)
                try Data("blocks completed-intent write".utf8).write(to: state)
            }
            do {
                if removeHost { try await s.remove(id) }
                else { _ = try await s.hosts() }
                XCTFail("a failed completed-intent write must not be reported as success")
            } catch is CocoaError {}
            XCTAssertNil(try tokens.read(id), "the token was removed before recording cleanup completion failed")
            try FileManager.default.removeItem(at: state)
            try FileManager.default.moveItem(at: preserved, to: state)
            let reopened = ArgoHostStore(fileURL: file, tokens: tokens) { _, _ in throw CancellationError() }
            let loaded = try await reopened.hosts()
            XCTAssertTrue(loaded.isEmpty)
            XCTAssertEqual(tokens.deletions, [id, id], "the still-durable intent must be retried idempotently")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            XCTAssertNil(metadata?["pendingCredentialCleanup"])
        }
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
}

private final class InterceptingDeviceTokens: DeviceTokenStoring, @unchecked Sendable {
    let memory: InMemoryDeviceTokens
    var afterSave: (() throws -> Void)?
    var saveError: Error?
    var beforeDelete: (() throws -> Void)?
    var deleteError: Error?
    private(set) var savedID: UUID?
    private(set) var deletions: [UUID] = []
    init(memory: InMemoryDeviceTokens) { self.memory = memory }
    func save(_ token: String, for host: UUID) throws {
        if let saveError { throw saveError }
        try memory.save(token, for: host)
        savedID = host
        let callback = afterSave
        afterSave = nil
        try callback?()
    }
    func read(_ host: UUID) throws -> String? { try memory.read(host) }
    func delete(_ host: UUID) throws {
        deletions.append(host)
        let callback = beforeDelete
        beforeDelete = nil
        try callback?()
        if let deleteError { throw deleteError }
        memory.delete(host)
    }
}
