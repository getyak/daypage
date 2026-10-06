import Foundation
import CryptoKit
import Testing
import DayPageModels
import DayPageStorage
@testable import DayPage

extension DayPageSerialSwiftTests {
@MainActor
@Suite("System action UI model")
struct SystemActionUIModelTests {
    #if DEBUG
    @Test func dedicatedQAIdentitiesUseSeparatePreferenceSuites() {
        #expect(SystemActionSharedSummaryStore.appGroupIdentifier(for: "com.daypage.app.qa-unit") == "group.com.daypage.qa-unit")
        #expect(SystemActionSharedSummaryStore.appGroupIdentifier(for: "com.daypage.app.qa-ui") == "group.com.daypage.qa-ui")
        #expect(SystemActionSharedSummaryStore.appGroupIdentifier(for: "com.daypage.app.qa-unit.DayPageWidget") == "group.com.daypage.qa-unit")
        #expect(SystemActionSharedSummaryStore.appGroupIdentifier(for: "com.daypage.app.qa-ui.DayPageWidget") == "group.com.daypage.qa-ui")
    }

    @Test func ordinaryIdentitiesKeepExistingPreferenceSuite() {
        for identity in ["com.daypage.app", "com.daypage.app.qa-ui-other", nil] as [String?] {
            #expect(SystemActionSharedSummaryStore.appGroupIdentifier(for: identity) == "group.com.daypage")
        }
    }
    #endif

    @Test func editingCreatesNewRevisionAndPayloadHash() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = try SystemActionProposal(
            payload: .calendarEvent(.init(
                title: "Initial",
                startAt: now,
                endAt: now.addingTimeInterval(3_600)
            )),
            title: "Initial",
            rationale: "Before edit",
            creatorSource: .systemEntry,
            creatorDeviceID: "device-a"
        )
        var draft = SystemActionEditableDraft(proposal: original)
        draft.title = "Revised"

        let revised = try draft.makeRevised(now: now.addingTimeInterval(60))

        #expect(revised.id == original.id)
        #expect(revised.revision == original.revision + 1)
        #expect(revised.payloadHash != original.payloadHash)
        #expect(revised.lifecycleState == .pendingReview)
        #expect(revised.createdAt == original.createdAt)
    }

    @Test func reviewBoundsTitleAndRationaleToContractLimits() throws {
        let original = try reminderProposal()
        var draft = SystemActionEditableDraft(proposal: original)
        draft.title = String(repeating: "T", count: 300)
        draft.rationale = String(repeating: "R", count: 900)

        let revised = try draft.makeRevised()

        #expect(revised.title.count == 160)
        #expect(revised.rationale.count == 500)
        guard case .reminder(let payload) = revised.payload else {
            Issue.record("Expected reminder payload")
            return
        }
        #expect(payload.title.count == 160)
    }

    @Test func routeEditorEnforcesAddressOrCoordinateDestination() throws {
        let original = try SystemActionProposal(
            payload: .route(.init(destination: .init(label: "Office", address: "1 Infinite Loop"), mode: .any)),
            title: "Route",
            rationale: "Review route",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        var draft = SystemActionEditableDraft(proposal: original)
        draft.latitude = "31.2304"
        draft.longitude = "121.4737"
        guard case .route(let addressPayload) = try draft.makePayload() else {
            Issue.record("Expected route payload")
            return
        }
        #expect(addressPayload.mode == .any)
        #expect(addressPayload.destination.address == "1 Infinite Loop")
        #expect(addressPayload.destination.latitude == nil)
        #expect(addressPayload.destination.longitude == nil)
        #expect(addressPayload.opensImmediately)

        draft.routeDestinationMode = .coordinates
        draft.latitude = "31.2304"
        draft.longitude = "121.4737"
        guard case .route(let coordinatePayload) = try draft.makePayload() else {
            Issue.record("Expected coordinate route payload")
            return
        }
        #expect(coordinatePayload.destination.address == nil)
        #expect(coordinatePayload.destination.latitude == 31.2304)
        #expect(coordinatePayload.destination.longitude == 121.4737)

        draft.longitude = ""
        #expect(throws: SystemActionDraftValidationError.routeCoordinatePairRequired) {
            try draft.makePayload()
        }
    }

    @Test func editorDropsUnsupportedCalendarReminderAndNotificationV1Fields() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = try SystemActionProposal(
            payload: .calendarEvent(.init(
                title: "Event",
                startAt: now,
                endAt: now.addingTimeInterval(3_600),
                location: .init(label: "Office", latitude: 31.23, longitude: 121.47)
            )),
            title: "Event",
            rationale: "Review",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        var calendarDraft = SystemActionEditableDraft(proposal: calendar)
        calendarDraft.primaryText = "Meeting room"
        guard case .calendarEvent(let calendarPayload) = try calendarDraft.makePayload() else {
            Issue.record("Expected calendar payload")
            return
        }
        #expect(calendarPayload.calendarHint == nil)
        #expect(calendarPayload.location?.label == "Meeting room")
        #expect(calendarPayload.location?.latitude == nil)
        #expect(calendarPayload.location?.longitude == nil)

        var reminderDraft = SystemActionEditableDraft(proposal: try reminderProposal())
        reminderDraft.primaryText = "Unsupported list"
        guard case .reminder(let reminderPayload) = try reminderDraft.makePayload() else {
            Issue.record("Expected reminder payload")
            return
        }
        #expect(reminderPayload.listHint == nil)

        let notification = try SystemActionProposal(
            payload: .notification(.init(title: "Alert", body: "Body", fireAt: now)),
            title: "Alert",
            rationale: "Review",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        var notificationDraft = SystemActionEditableDraft(proposal: notification)
        notificationDraft.boolOption = false
        notificationDraft.primaryText = "unsupported-thread"
        guard case .notification(let notificationPayload) = try notificationDraft.makePayload() else {
            Issue.record("Expected notification payload")
            return
        }
        #expect(notificationPayload.playsSound)
        #expect(notificationPayload.threadIdentifier == nil)
    }

    @Test func contactEditorUsesFixedLabelsAndRejectsMoreThanFiveValues() throws {
        let proposal = try SystemActionProposal(
            payload: .contactDraft(.init(givenName: "Ada", familyName: "Lovelace")),
            title: "Ada Lovelace",
            rationale: "Review",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        var draft = SystemActionEditableDraft(proposal: proposal)
        draft.phoneLines = "+1 111\n+1 222"
        draft.emailLines = "ada@example.com\nwork@example.com"
        guard case .contactDraft(let payload) = try draft.makePayload() else {
            Issue.record("Expected contact payload")
            return
        }
        #expect(payload.phoneNumbers.map(\.label) == ["phone", "phone"])
        #expect(payload.emailAddresses.map(\.label) == ["email", "email"])

        draft.phoneLines = (1...6).map { "+1 555 000 \($0)" }.joined(separator: "\n")
        #expect(throws: SystemActionDraftValidationError.self) {
            try draft.makePayload()
        }
    }

    @Test func momentEditorNeverCarriesPreciseCoordinates() throws {
        let proposal = try SystemActionProposal(
            payload: .moment(.init(
                occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
                title: "Now",
                location: .init(label: "Park")
            )),
            title: "Now",
            rationale: "Review",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        var draft = SystemActionEditableDraft(proposal: proposal)
        draft.latitude = "31.2304"
        draft.longitude = "121.4737"
        guard case .moment(let payload) = try draft.makePayload() else {
            Issue.record("Expected moment payload")
            return
        }
        #expect(payload.location?.label == "Park")
        #expect(payload.location?.latitude == nil)
        #expect(payload.location?.longitude == nil)

        draft.primaryText = ""
        #expect(throws: SystemActionDraftValidationError.momentPlaceLabelRequired) {
            try draft.makePayload()
        }
    }

    @Test func captureEditorPreservesEverySupportedInputMode() throws {
        let original = try SystemActionProposal(
            payload: .capture(.init(captureKind: .document, suggestedTitle: "Evidence")),
            title: "Capture",
            rationale: "User selected capture",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        let modes: [SystemActionCaptureKind] = [
            .text, .photo, .camera, .document, .textScan, .ink, .file, .voice,
        ]

        for mode in modes {
            var draft = SystemActionEditableDraft(proposal: original)
            draft.mode = mode.rawValue
            guard case .capture(let payload) = try draft.makePayload() else {
                Issue.record("Expected capture payload for \(mode.rawValue)")
                continue
            }
            #expect(payload.captureKind.rawValue == mode.rawValue)
        }
    }

    @Test func localContextProposalContainsOnlyLocalReferenceNotRawValues() throws {
        let model = makeModel()
        let id = UUID()
        let record = SystemActionLocalContextRecord(
            id: id,
            kind: .healthSummary,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            boundedValues: ["step_count": "private-12345"]
        )

        let proposal = try model.makeLocalContextProposal(record)

        #expect(proposal.redactionLevel == .privateOnLockScreen)
        #expect(proposal.targetDevice == .creatingDevice)
        #expect(proposal.expiresAt == record.retentionExpiresAt())
        guard case .localContextAttachment(let payload) = proposal.payload else {
            Issue.record("Expected local-context reference payload")
            return
        }
        #expect(payload.summaryCode == id.uuidString.lowercased())
        let cloudJSON = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
        #expect(!cloudJSON.contains("private-12345"))
        #expect(!cloudJSON.contains("step_count"))
    }

    @Test func stagedLocalContextCanBeDeletedWhenReviewIsDismissed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-local-context-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SystemActionLocalContextStore(directoryURL: directory)
        let record = SystemActionLocalContextRecord(
            kind: .placeSummary,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            boundedValues: ["latitude": "31.230400"]
        )
        let url = directory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")

        try await store.save(record)
        #expect(FileManager.default.fileExists(atPath: url.path))

        try await store.delete(id: record.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func localContextRetentionPrunesAgeCountAndTotalBytesWithoutUnderflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-local-context-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()

        let countDirectory = root.appendingPathComponent("count", isDirectory: true)
        let countStore = SystemActionLocalContextStore(
            directoryURL: countDirectory,
            retentionPolicy: .init(maximumAge: 3_600, maximumRecordCount: 2, maximumTotalByteCount: 1_048_576),
            now: { now }
        )
        var countRecords: [SystemActionLocalContextRecord] = []
        for index in 0..<2 {
            let record = SystemActionLocalContextRecord(
                kind: .weatherSummary,
                observedAt: now,
                boundedValues: ["condition": "bounded-\(index)"]
            )
            countRecords.append(record)
            try await countStore.save(.init(
                id: record.id,
                kind: record.kind,
                observedAt: record.observedAt,
                boundedValues: record.boundedValues
            ))
        }
        await #expect(throws: (any Error).self) {
            try await countStore.save(.init(
                kind: .weatherSummary,
                observedAt: now,
                boundedValues: ["condition": "must-not-evict"]
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: countDirectory.path).count == 2)
        for record in countRecords {
            let url = countDirectory.appendingPathComponent("\(record.id.uuidString.lowercased()).json")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let firstRecordURL = countDirectory.appendingPathComponent(
            "\(countRecords[0].id.uuidString.lowercased()).json"
        )
        let firstRecordData = try Data(contentsOf: firstRecordURL)
        await #expect(throws: (any Error).self) {
            try await countStore.save(.init(
                id: countRecords[0].id,
                kind: .weatherSummary,
                observedAt: now,
                boundedValues: ["condition": "replacement-must-not-win"]
            ))
        }
        #expect(try Data(contentsOf: firstRecordURL) == firstRecordData)

        let ageDirectory = root.appendingPathComponent("age", isDirectory: true)
        let ageStore = SystemActionLocalContextStore(
            directoryURL: ageDirectory,
            retentionPolicy: .init(maximumAge: 60, maximumRecordCount: 8, maximumTotalByteCount: 1_048_576),
            now: { now }
        )
        let semanticallyOldRecord = SystemActionLocalContextRecord(
            kind: .weatherSummary,
            observedAt: now.addingTimeInterval(-61),
            boundedValues: ["condition": "stale"]
        )
        await #expect(throws: (any Error).self) {
            try await ageStore.save(semanticallyOldRecord)
        }
        let semanticallyOldURL = ageDirectory.appendingPathComponent(
            "\(semanticallyOldRecord.id.uuidString.lowercased()).json"
        )
        #expect(!FileManager.default.fileExists(atPath: semanticallyOldURL.path))
        try FileManager.default.createDirectory(at: ageDirectory, withIntermediateDirectories: true)
        let corruptURL = ageDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try Data("not-json".utf8).write(to: corruptURL)
        try await ageStore.prune()
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))

        let quotaRecord = SystemActionLocalContextRecord(
            kind: .healthSummary,
            observedAt: now,
            boundedValues: ["summary": String(repeating: "x", count: 200)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encodedByteCount = try encoder.encode(quotaRecord).count
        let quotaDirectory = root.appendingPathComponent("quota", isDirectory: true)
        let quotaStore = SystemActionLocalContextStore(
            directoryURL: quotaDirectory,
            retentionPolicy: .init(
                maximumAge: 3_600,
                maximumRecordCount: 8,
                maximumTotalByteCount: encodedByteCount - 1
            ),
            now: { now }
        )
        await #expect(throws: (any Error).self) {
            try await quotaStore.save(quotaRecord)
        }
        let quotaURL = quotaDirectory.appendingPathComponent("\(quotaRecord.id.uuidString.lowercased()).json")
        #expect(!FileManager.default.fileExists(atPath: quotaURL.path))

        let normalizedDirectory = root.appendingPathComponent("normalized", isDirectory: true)
        let normalizedStore = SystemActionLocalContextStore(
            directoryURL: normalizedDirectory,
            retentionPolicy: .init(maximumAge: 0, maximumRecordCount: 0, maximumTotalByteCount: 1_048_576),
            now: { now }
        )
        try await normalizedStore.save(.init(
            kind: .weatherSummary,
            observedAt: now,
            boundedValues: ["condition": "first"]
        ))
        await #expect(throws: (any Error).self) {
            try await normalizedStore.save(.init(
                kind: .weatherSummary,
                observedAt: now,
                boundedValues: ["condition": "second"]
            ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: normalizedDirectory.path).count == 1)
    }

    @Test func localContextClearAllCannotDeleteVaultUserContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-local-context-clear-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contextDirectory = root
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("local-context", isDirectory: true)
        let rawDirectory = root.appendingPathComponent("raw", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let userFile = rawDirectory.appendingPathComponent("2026-08-27.md")
        try Data("private vault content".utf8).write(to: userFile)
        let store = SystemActionLocalContextStore(directoryURL: contextDirectory)
        try await store.save(.init(
            kind: .weatherSummary,
            observedAt: Date(),
            boundedValues: ["condition": "clear"]
        ))

        try await store.clearAll()

        #expect(!FileManager.default.fileExists(atPath: contextDirectory.path))
        #expect(try String(contentsOf: userFile, encoding: .utf8) == "private vault content")
    }

    @Test func boundedFileCopierStreamsExactBytesAndRejectsOverflow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-bounded-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        let copied = directory.appendingPathComponent("copied.bin")
        let overflow = directory.appendingPathComponent("overflow.bin")
        let bytes = Data((0..<255).map(UInt8.init))
        try bytes.write(to: source)

        let copiedCount = try SystemActionBoundedFileCopier.copy(
            from: source,
            to: copied,
            maximumByteCount: bytes.count
        )
        #expect(copiedCount == bytes.count)
        #expect(try Data(contentsOf: copied) == bytes)

        #expect(throws: (any Error).self) {
            try SystemActionBoundedFileCopier.copy(
                from: source,
                to: overflow,
                maximumByteCount: bytes.count - 1
            )
        }
        #expect(!FileManager.default.fileExists(atPath: overflow.path))
    }

    @Test func photoAndContactContextFactoriesStoreOnlyOpaqueHashes() throws {
        let rawAssetIdentifier = "private-photos-library-identifier"
        let photo = SystemActionLocalContextRecordFactory.photo(
            assetIdentifier: rawAssetIdentifier,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(photo.kind == .photo)
        #expect(photo.boundedValues["asset_reference_hash"]?.count == 64)
        #expect(!photo.boundedValues.values.contains(rawAssetIdentifier))

        let firstHash = String(repeating: "a", count: 64)
        let secondHash = String(repeating: "b", count: 64)
        let contacts = try SystemActionLocalContextRecordFactory.contacts(
            referenceHashes: [firstHash, secondHash, firstHash],
            observedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        #expect(contacts.kind == .contactSelection)
        #expect(contacts.boundedValues.count == 2)
        #expect(Set(contacts.boundedValues.values) == [firstHash, secondHash])
        for nonASCIIHash in [
            String(repeating: "١", count: 64),
            String(repeating: "１", count: 64),
        ] {
            #expect(throws: (any Error).self) {
                try SystemActionLocalContextRecordFactory.contacts(referenceHashes: [nonASCIIHash])
            }
        }

        let model = makeModel()
        for record in [photo, contacts] {
            let proposal = try model.makeLocalContextProposal(record)
            let cloudJSON = String(decoding: try JSONEncoder().encode(proposal), as: UTF8.self)
            #expect(!cloudJSON.contains(rawAssetIdentifier))
            #expect(!cloudJSON.contains(firstHash))
            #expect(!cloudJSON.contains(secondHash))
            #expect(cloudJSON.contains(record.id.uuidString.lowercased()))
        }
    }

    @Test func systemEntrySeedBoundsExternalTextBeforeValidation() throws {
        let model = makeModel()
        let proposal = try model.makeSeedProposal(.init(
            kind: "contact_draft",
            title: String(repeating: "N", count: 300),
            notes: String(repeating: "O", count: 900)
        ))

        #expect(proposal.title.count == 160)
        #expect(proposal.rationale.count == 500)
        guard case .contactDraft(let payload) = proposal.payload else {
            Issue.record("Expected contact draft payload")
            return
        }
        #expect(payload.givenName.count == 100)
        #expect(payload.organization?.count == 160)
    }

    @Test func extensionNavigationBridgeIsBoundedAndOneShot() throws {
        let proposalID = UUID()
        SystemActionSharedSummaryStore.requestOpenCenter(proposalID: proposalID.uuidString)

        let first = SystemActionSharedSummaryStore.consumeOpenCenterRequest()
        let second = SystemActionSharedSummaryStore.consumeOpenCenterRequest()

        #expect(first.requested)
        #expect(first.proposalID == proposalID)
        #expect(!second.requested)
        #expect(second.proposalID == nil)
    }

    @Test func preApprovalSystemSurfaceSummaryIsAlwaysGeneric() throws {
        let proposal = try SystemActionProposal(
            payload: .reminder(.init(title: "Secret acquisition target")),
            title: "Secret acquisition target",
            rationale: "Agent-provided and not yet reviewed",
            creatorSource: .localAgent,
            creatorDeviceID: "device-a",
            redactionLevel: .boundedSummary
        )

        let pending = SystemActionSystemSurfacePrivacy.summary(for: proposal, decisions: [])
        #expect(pending.title == SystemActionSystemSurfacePrivacy.genericTitle)
        #expect(pending.kind == SystemActionSystemSurfacePrivacy.genericKind)
        #expect(pending.privacySensitive)

        let approval = try SystemActionDecision(
            proposalID: proposal.id,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            outcome: .approved,
            deviceID: "device-a"
        )
        let approved = SystemActionSystemSurfacePrivacy.summary(
            for: try proposal.withLifecycleState(.approved),
            decisions: [approval]
        )
        #expect(approved.title == proposal.title)
        #expect(approved.kind == proposal.kind.rawValue)
        #expect(!approved.privacySensitive)

        let privateProposal = try SystemActionProposal(
            payload: proposal.payload,
            title: proposal.title,
            rationale: proposal.rationale,
            creatorSource: .localAgent,
            creatorDeviceID: "device-a",
            redactionLevel: .privateOnLockScreen
        )
        let privateApproval = try SystemActionDecision(
            proposalID: privateProposal.id,
            proposalRevision: privateProposal.revision,
            payloadHash: privateProposal.payloadHash,
            outcome: .approved,
            deviceID: "device-a"
        )
        let privateApproved = SystemActionSystemSurfacePrivacy.summary(
            for: try privateProposal.withLifecycleState(.approved),
            decisions: [privateApproval]
        )
        #expect(privateApproved.title == SystemActionSystemSurfacePrivacy.genericTitle)
        #expect(privateApproved.kind == SystemActionSystemSurfacePrivacy.genericKind)
        #expect(privateApproved.privacySensitive)
    }

    @Test func constructedProposalCopyResolvesLocalizationKeysBeforePersistence() async throws {
        let model = makeModel()
        let seed = try model.makeSeedProposal(.init(kind: "reminder", title: "", notes: nil))
        #expect(seed.title == NSLocalizedString("system_action.seed.default.reminder", comment: ""))
        #expect(seed.rationale == NSLocalizedString("system_action.seed.rationale", comment: ""))

        let focus = try model.makeFocusProposal(.init(title: "", durationSeconds: 1_500))
        #expect(focus.title == NSLocalizedString("system_action.seed.default.focus_session", comment: ""))
        #expect(focus.rationale == NSLocalizedString("system_action.focus.rationale", comment: ""))

        let context = try model.makeLocalContextProposal(.init(
            kind: .weatherSummary,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            boundedValues: [:]
        ))
        #expect(context.title == NSLocalizedString("system_action.local_context.title.weather", comment: ""))
        #expect(context.rationale == NSLocalizedString("system_action.local_context.rationale", comment: ""))
        #expect(SystemActionSystemSurfacePrivacy.genericTitle == NSLocalizedString(
            "system_action.privacy.generic_title",
            comment: ""
        ))

        let failedModel = makeModel(prepareAccountBoundary: { throw UnlocalizedTestFailure() })
        await failedModel.refresh()
        #expect(failedModel.errorMessage == NSLocalizedString("system_action.error.operation_generic", comment: ""))

        for value in [seed.title, seed.rationale, focus.title, focus.rationale, context.title, context.rationale] {
            #expect(!value.hasPrefix("system_action."))
        }
    }

    @Test func sharedSummaryStoreClearRemovesSnapshotAndNavigationBridge() throws {
        let suiteName = "daypage-system-action-summary-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(Data("private".utf8), forKey: SystemActionSharedSummaryStore.snapshotKey)
        defaults.set(UUID().uuidString, forKey: SystemActionSharedSummaryStore.openCenterRequestKey)

        SystemActionSharedSummaryStore.clear(defaults: defaults)

        #expect(defaults.object(forKey: SystemActionSharedSummaryStore.snapshotKey) == nil)
        #expect(defaults.object(forKey: SystemActionSharedSummaryStore.openCenterRequestKey) == nil)
    }

    @Test func accountBoundaryClearsLedgerBeforeSwitchingBinding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-account-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SystemActionLedger(vaultRootURL: root, deviceID: "device-a")
        let suiteName = "daypage-account-boundary-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let account = AccountIDBox("account-a-hash")
        let clears = AsyncCounter()
        let entitySuite = "daypage-account-boundary-entities-\(UUID().uuidString)"
        let entityPrivateSuite = "daypage-account-boundary-private-\(UUID().uuidString)"
        let entityDefaults = try #require(UserDefaults(suiteName: entitySuite))
        let entityPrivateDefaults = try #require(UserDefaults(suiteName: entityPrivateSuite))
        defer {
            entityDefaults.removePersistentDomain(forName: entitySuite)
            entityPrivateDefaults.removePersistentDomain(forName: entityPrivateSuite)
        }
        let contextDirectory = root
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("local-context", isDirectory: true)
        let contextStore = SystemActionLocalContextStore(directoryURL: contextDirectory)
        let boundary = SystemActionAccountBoundary(
            ledger: ledger,
            defaults: defaults,
            accountIDProvider: { await account.value() },
            clearExternalSurfaces: {
                try await contextStore.clearAll()
                guard let scopedEntityDefaults = UserDefaults(suiteName: entitySuite),
                      let scopedPrivateDefaults = UserDefaults(suiteName: entityPrivateSuite) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                DayPageReadOnlyEntitySnapshotStore.clear(
                    defaults: scopedEntityDefaults,
                    privateDefaults: scopedPrivateDefaults
                )
                await clears.increment()
            }
        )
        try await boundary.prepare()
        try await contextStore.save(.init(
            kind: .weatherSummary,
            observedAt: Date(),
            boundedValues: ["condition": "account-a"]
        ))
        entityDefaults.set(Data("account-a".utf8), forKey: DayPageReadOnlyEntitySnapshotStore.snapshotKey)
        entityPrivateDefaults.set(
            Data(repeating: 1, count: 32),
            forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey
        )
        let proposal = try reminderProposal()
        try await ledger.saveProposal(proposal)
        #expect((try await ledger.snapshot()).proposals.count == 1)

        await account.set("account-b-hash")
        try await boundary.prepare()

        let switched = try await ledger.snapshot()
        #expect(switched.proposals.isEmpty)
        #expect(switched.pendingOutbox.isEmpty)
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == "account-b-hash")
        #expect(!defaults.bool(forKey: SystemActionAccountBoundary.quarantineKey))
        #expect(!FileManager.default.fileExists(atPath: contextDirectory.path))
        #expect(entityDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.snapshotKey) == nil)
        #expect(entityPrivateDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey) == nil)

        try await contextStore.save(.init(
            kind: .weatherSummary,
            observedAt: Date(),
            boundedValues: ["condition": "account-b"]
        ))
        entityDefaults.set(Data("account-b".utf8), forKey: DayPageReadOnlyEntitySnapshotStore.snapshotKey)
        entityPrivateDefaults.set(
            Data(repeating: 2, count: 32),
            forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey
        )
        try await ledger.saveProposal(proposal)
        await account.set(nil)
        do {
            try await boundary.prepare()
            Issue.record("A signed-out boundary must fail closed")
        } catch {
            #expect(error as? SystemActionAccountBoundaryError == .authenticationRequired)
        }
        #expect((try await ledger.snapshot()).proposals.isEmpty)
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: contextDirectory.path))
        #expect(entityDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.snapshotKey) == nil)
        #expect(entityPrivateDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey) == nil)

        try await boundary.clearForSignOut()
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == nil)
        #expect(await clears.value() == 3)
    }

    @Test func accountBoundaryErrorsAreLocalizedAndHumanReadable() {
        let signedOut = SystemActionAccountBoundaryError.authenticationRequired.errorDescription
        let invalid = SystemActionAccountBoundaryError.invalidAccountIdentifier.errorDescription

        #expect(signedOut == NSLocalizedString("system_action.error.sign_in_required", value: "请先登录 DayPage，再使用系统动作。", comment: ""))
        #expect(invalid == NSLocalizedString("system_action.error.invalid_account", value: "当前账号标识无效。请重新登录后再试。", comment: ""))
        #expect(signedOut?.isEmpty == false)
        #expect(invalid?.isEmpty == false)
    }

    @Test func quarantinedSameIdentityRecoveryPreservesUnresolvedLedgerEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-account-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SystemActionLedger(vaultRootURL: root, deviceID: "device-a")
        let proposal = try reminderProposal()
        try await ledger.saveProposal(proposal)
        let suite = "daypage-account-recovery-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("account-a-hash", forKey: SystemActionAccountBoundary.bindingKey)
        defaults.set(true, forKey: SystemActionAccountBoundary.quarantineKey)
        let clears = AsyncCounter()
        let boundary = SystemActionAccountBoundary(
            ledger: ledger,
            defaults: defaults,
            accountIDProvider: { "account-a-hash" },
            clearExternalSurfaces: { await clears.increment() }
        )

        try await boundary.prepare()

        #expect((try await ledger.snapshot()).proposals == [proposal])
        #expect(await clears.value() == 1)
        #expect(!defaults.bool(forKey: SystemActionAccountBoundary.quarantineKey))
        #expect(await boundary.isReadyForCurrentIdentity())
    }

    @Test func signOutPreflightClosesBarrierBeforeIdentityRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-signout-preflight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SystemActionLedger(vaultRootURL: root, deviceID: "device-a")
        let suite = "daypage-signout-preflight-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountIDBox("account-a-hash")
        let barrierBegins = AsyncCounter()
        let barrierEnds = AsyncCounter()
        let boundary = SystemActionAccountBoundary(
            ledger: ledger,
            defaults: defaults,
            accountIDProvider: { await account.value() },
            clearExternalSurfaces: {}
        )
        try await boundary.prepare()
        try await ledger.saveProposal(try reminderProposal())
        boundary.installTransitionBarrier(
            begin: { await barrierBegins.increment() },
            end: { await barrierEnds.increment() }
        )

        try await boundary.beginSignOutTransition()

        #expect(await barrierBegins.value() == 1)
        #expect(await barrierEnds.value() == 0)
        #expect(defaults.bool(forKey: SystemActionAccountBoundary.quarantineKey))
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == "account-a-hash")

        // Supabase identity changes only after the barrier/preflight succeeds.
        await account.set(nil)
        try await boundary.finishSignOutTransition()

        #expect(await barrierEnds.value() == 1)
        #expect(!defaults.bool(forKey: SystemActionAccountBoundary.quarantineKey))
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == nil)
        #expect((try await ledger.snapshot()).proposals.isEmpty)
    }

    @Test func signOutPreflightPreservesIdentityWhenRemoteClaimIsUnresolved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-signout-unresolved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = SystemActionLedger(vaultRootURL: root, deviceID: "device-a")
        let proposal = try reminderProposal()
        try await ledger.saveProposal(proposal)
        try await ledger.recordDecision(try .init(
            proposalID: proposal.id,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            outcome: .approved,
            deviceID: "device-a"
        ))
        let preparation = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            enforceLocalExpiry: false
        )
        guard case .ready(let planned) = preparation else {
            Issue.record("Expected a claim plan")
            return
        }
        _ = try await ledger.prepareRemoteClaim(operationID: planned.operationID)
        let suite = "daypage-signout-unresolved-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("account-a-hash", forKey: SystemActionAccountBoundary.bindingKey)
        let barrierEnds = AsyncCounter()
        let boundary = SystemActionAccountBoundary(
            ledger: ledger,
            defaults: defaults,
            accountIDProvider: { "account-a-hash" },
            clearExternalSurfaces: {}
        )
        boundary.installTransitionBarrier(
            begin: {},
            end: { await barrierEnds.increment() }
        )

        await #expect(throws: SystemActionLedgerError.unresolvedRemoteCoordination) {
            try await boundary.beginSignOutTransition()
        }

        #expect(await barrierEnds.value() == 1)
        #expect(!defaults.bool(forKey: SystemActionAccountBoundary.quarantineKey))
        #expect(defaults.string(forKey: SystemActionAccountBoundary.bindingKey) == "account-a-hash")
        #expect((try await ledger.snapshot()).executions.first?.state == .claimingRemote)
    }

    @Test func executionModeRequiresRemoteSessionConnectivityAndFullProposalEligibility() {
        switch SystemActionRuntime.executionMode(
            isNetworkUnavailable: true,
            isRemoteAuthenticated: true,
            isProposalCloudEligible: true
        ) {
        case .offline: break
        default: Issue.record("Unavailable connectivity must select offline execution up front")
        }
        switch SystemActionRuntime.executionMode(
            isNetworkUnavailable: false,
            isRemoteAuthenticated: false,
            isProposalCloudEligible: true
        ) {
        case .offline: break
        default: Issue.record("Signed-out actions must stay device-local")
        }
        switch SystemActionRuntime.executionMode(
            isNetworkUnavailable: false,
            isRemoteAuthenticated: true,
            isProposalCloudEligible: false
        ) {
        case .offline: break
        default: Issue.record("Private-device proposals must stay device-local even while online")
        }
        switch SystemActionRuntime.executionMode(
            isNetworkUnavailable: false,
            isRemoteAuthenticated: true,
            isProposalCloudEligible: true
        ) {
        case .onlineRequired: break
        default: Issue.record("Cloud-eligible authenticated actions must use remote coordination")
        }
    }

    @Test func readOnlyEntitySnapshotIsBoundedOneShotAndClearedAcrossAccounts() throws {
        let appSuite = "daypage-read-entities-app-\(UUID().uuidString)"
        let privateSuite = "daypage-read-entities-private-\(UUID().uuidString)"
        let appDefaults = try #require(UserDefaults(suiteName: appSuite))
        let privateDefaults = try #require(UserDefaults(suiteName: privateSuite))
        defer {
            appDefaults.removePersistentDomain(forName: appSuite)
            privateDefaults.removePersistentDomain(forName: privateSuite)
        }
        let memoID = UUID().uuidString.lowercased()
        let placeID = String(repeating: "a", count: 64)
        let snapshot = DayPageReadOnlyEntitySnapshotStore.Snapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            memos: (0..<40).map { index in
                .init(id: index == 0 ? memoID : UUID().uuidString.lowercased(), dateString: "2026-08-27", type: "text")
            },
            dailyPages: [.init(id: "2026-08-27", memoCount: 1)],
            places: [.init(id: placeID)]
        )
        #expect(DayPageReadOnlyEntitySnapshotStore.write(snapshot, defaults: appDefaults))
        #expect(DayPageReadOnlyEntitySnapshotStore.snapshot(defaults: appDefaults)?.memos.count == 32)

        DayPageReadOnlyEntitySnapshotStore.requestOpen(
            kind: .memo,
            identifier: memoID,
            dateString: "2026-08-27",
            defaults: appDefaults
        )
        let request = try #require(DayPageReadOnlyEntitySnapshotStore.consumeNavigationRequest(defaults: appDefaults))
        #expect(request.url?.absoluteString.contains("daypage://memo/open") == true)
        #expect(DayPageReadOnlyEntitySnapshotStore.consumeNavigationRequest(defaults: appDefaults) == nil)
        DayPageReadOnlyEntitySnapshotStore.requestOpen(
            kind: .dailyPage,
            identifier: "2026-99-99",
            defaults: appDefaults
        )
        #expect(DayPageReadOnlyEntitySnapshotStore.consumeNavigationRequest(defaults: appDefaults) == nil)
        for nonASCIIIdentifier in [
            String(repeating: "١", count: 64),
            String(repeating: "１", count: 64),
        ] {
            DayPageReadOnlyEntitySnapshotStore.requestOpen(
                kind: .place,
                identifier: nonASCIIIdentifier,
                defaults: appDefaults
            )
            #expect(DayPageReadOnlyEntitySnapshotStore.consumeNavigationRequest(defaults: appDefaults) == nil)

            let invalidSnapshot = DayPageReadOnlyEntitySnapshotStore.Snapshot(
                schemaVersion: 1,
                generatedAt: Date(),
                memos: [],
                dailyPages: [],
                places: [.init(id: nonASCIIIdentifier)]
            )
            #expect(DayPageReadOnlyEntitySnapshotStore.write(invalidSnapshot, defaults: appDefaults))
            #expect(DayPageReadOnlyEntitySnapshotStore.snapshot(defaults: appDefaults) == nil)
        }

        privateDefaults.set([placeID: "private-place-slug"], forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceMapKey)
        privateDefaults.set(Data(repeating: 7, count: 32), forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey)
        DayPageReadOnlyEntitySnapshotStore.clear(defaults: appDefaults, privateDefaults: privateDefaults)
        #expect(DayPageReadOnlyEntitySnapshotStore.snapshot(defaults: appDefaults) == nil)
        #expect(privateDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceMapKey) == nil)
        #expect(privateDefaults.object(forKey: DayPageReadOnlyEntitySnapshotStore.privatePlaceIdentifierKey) == nil)
    }

    @Test func readOnlyPublicationNeverExportsRawMemoOrDictionaryAttackablePlaceData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-read-entity-publication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rawDirectory = root.appendingPathComponent("raw", isDirectory: true)
        let placeDirectory = root
            .appendingPathComponent("wiki", isDirectory: true)
            .appendingPathComponent("places", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: placeDirectory, withIntermediateDirectories: true)
        let memo = Memo(
            id: UUID(),
            type: .location,
            created: Date(),
            location: .init(name: "Secret Home", lat: 31.2304, lng: 121.4737),
            body: "confidential memo body"
        )
        try RawStorage.serialize([memo]).write(
            to: rawDirectory.appendingPathComponent("2026-08-27.md"),
            atomically: true,
            encoding: .utf8
        )
        let slug = "secret-home"
        try "# Secret Home\ncoordinates: 31.2304,121.4737".write(
            to: placeDirectory.appendingPathComponent("\(slug).md"),
            atomically: true,
            encoding: .utf8
        )
        let key = Data(repeating: 0x5a, count: 32)

        let publication = DayPageReadOnlyEntitySnapshotPublisher.buildPublication(
            vaultRoot: root,
            placeIdentifierKey: key
        )
        let publicJSON = String(decoding: try JSONEncoder().encode(publication.snapshot), as: UTF8.self)
        let unsaltedHash = SHA256.hash(data: Data(slug.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        #expect(publication.snapshot.memos.map(\.id) == [memo.id.uuidString.lowercased()])
        #expect(publication.snapshot.dailyPages.first?.memoCount == 1)
        #expect(publication.snapshot.places.count == 1)
        let place = try #require(publication.snapshot.places.first)
        #expect(place.id != unsaltedHash)
        #expect(publication.privatePlaceMap[place.id] == slug)
        for privateValue in ["confidential memo body", "Secret Home", slug, "31.2304", "121.4737"] {
            #expect(!publicJSON.contains(privateValue))
        }
    }

    @Test func draftIntentBoundsDeepLinkParameters() throws {
        let url = try #require(DraftSystemActionIntent.buildURL(
            kind: .reminder,
            title: String(repeating: "T", count: 300),
            notes: String(repeating: "N", count: 900)
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let title = components.queryItems?.first { $0.name == "title" }?.value
        let notes = components.queryItems?.first { $0.name == "notes" }?.value

        #expect(title?.count == 160)
        #expect(notes?.count == 500)
    }

    @Test func proposalPreviewExposesExactBoundFieldsAndDiffMap() throws {
        let proposal = try SystemActionProposal(
            payload: .route(.init(
                destination: .init(label: "Studio", latitude: 31.2304, longitude: 121.4737),
                mode: .walking
            )),
            title: "Walk",
            rationale: "Nearby",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
        let lines = SystemActionProposalPreview.lines(for: proposal)
        let fields = SystemActionProposalPreview.fieldMap(for: proposal)

        #expect(lines.contains { $0.contains("31.230400, 121.473700") })
        #expect(fields.values.contains { $0.contains(SystemActionRouteMode.walking.displayName) })
    }

    @Test func focusControlBridgeIsBoundedOneShotAndAccountClearable() throws {
        let suite = "daypage-focus-control-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        SystemActionSharedSummaryStore.requestFocusDraft(
            title: String(repeating: "专", count: 300),
            durationMinutes: 9_999,
            defaults: defaults
        )
        let request = try #require(SystemActionSharedSummaryStore.consumeFocusDraftRequest(defaults: defaults))
        #expect(request.title.utf8.count <= 160)
        #expect(request.title == String(repeating: "专", count: 53))
        #expect(request.durationMinutes == 1_440)
        #expect(SystemActionSharedSummaryStore.consumeFocusDraftRequest(defaults: defaults) == nil)

        let actionID = UUID()
        let requestedAt = Date()
        SystemActionSharedSummaryStore.requestFocusControl(
            actionID: actionID,
            operation: .pause,
            remainingSeconds: 1_234,
            requestedAt: requestedAt,
            defaults: defaults
        )
        let control = try #require(SystemActionSharedSummaryStore.pendingFocusControlRequest(
            now: requestedAt,
            defaults: defaults
        ))
        #expect(control.actionID == actionID)
        #expect(control.operation == .pause)
        #expect(control.remainingSeconds == 1_234)
        #expect(SystemActionSharedSummaryStore.pendingFocusControlRequest(
            now: requestedAt,
            defaults: defaults
        ) == control)
        SystemActionSharedSummaryStore.acknowledgeFocusControlRequest(control, defaults: defaults)
        #expect(SystemActionSharedSummaryStore.pendingFocusControlRequest(
            now: requestedAt,
            defaults: defaults
        ) == nil)

        SystemActionSharedSummaryStore.requestFocusDraft(title: "Write", durationMinutes: 25, defaults: defaults)
        SystemActionSharedSummaryStore.requestFocusControl(
            actionID: actionID,
            operation: .end,
            defaults: defaults
        )
        SystemActionSharedSummaryStore.clear(defaults: defaults)
        #expect(SystemActionSharedSummaryStore.consumeFocusDraftRequest(defaults: defaults) == nil)
        #expect(SystemActionSharedSummaryStore.consumeFocusControlRequest(defaults: defaults) == nil)
    }

    @Test func shareInboxBridgeDeduplicatesAndRequiresAcknowledgement() throws {
        let suite = "daypage-share-inbox-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let envelope = SystemActionSharedSummaryStore.ShareInboxEnvelope(
            schemaVersion: 1,
            id: UUID(),
            captureReference: "capture-opaque-1",
            captureKind: "photo",
            boundedTitle: "Shared image",
            createdAt: Date(),
            attachesToSource: false
        )

        SystemActionSharedSummaryStore.enqueueShareInboxEnvelope(envelope, defaults: defaults)
        SystemActionSharedSummaryStore.enqueueShareInboxEnvelope(envelope, defaults: defaults)
        #expect(SystemActionSharedSummaryStore.pendingShareInboxEnvelopes(defaults: defaults) == [envelope])
        SystemActionSharedSummaryStore.acknowledgeShareInboxEnvelope(id: envelope.id, defaults: defaults)
        #expect(SystemActionSharedSummaryStore.pendingShareInboxEnvelopes(defaults: defaults).isEmpty)
    }

    @Test func momentDraftPersistsPhotoAndCompletesAgainstExactProposal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-moment-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x2a, count: 2_048).write(to: source)
        let store = AppleMomentStore(vaultRootURL: root)
        let draftOccurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let approvedOccurredAt = Date(timeIntervalSince1970: 1_700_003_600)
        let draftID = try await store.saveDraft(
            title: "Old title",
            occurredAt: draftOccurredAt,
            contactReferenceHashes: [String(repeating: "a", count: 64)],
            photoFileURL: source,
            photoFileExtension: "jpg"
        )
        let proposal = try SystemActionProposal(
            payload: .moment(.init(
                occurredAt: approvedOccurredAt,
                title: "Approved title",
                selectedContactReferenceHashes: [String(repeating: "b", count: 64)]
            )),
            title: "Approved proposal",
            rationale: "Saved locally",
            sourceReferences: [.init(kind: .entity, identifier: "moment:\(draftID.uuidString.lowercased())")],
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )

        let completedID = try await store.complete(proposal: proposal, coordinate: nil)
        let isCompleted = await store.isCompleted(id: draftID, proposalID: proposal.id)
        #expect(completedID == draftID)
        #expect(isCompleted)
        #expect(FileManager.default.fileExists(atPath: root
            .appendingPathComponent("_agent/system-actions/moments/assets/\(draftID.uuidString.lowercased()).jpg").path))
        let manifestURL = root.appendingPathComponent(
            "_agent/system-actions/moments/\(draftID.uuidString.lowercased()).json"
        )
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        #expect(manifest["title"] as? String == "Approved title")
        #expect(manifest["contactReferenceHashes"] as? [String] == [String(repeating: "b", count: 64)])
        let encodedOccurredAt = try #require(manifest["occurredAt"] as? String)
        let storedOccurredAt = try #require(ISO8601DateFormatter().date(from: encodedOccurredAt))
        #expect(storedOccurredAt == approvedOccurredAt)
    }

    @Test func rejectedMomentDraftCleanupRemovesManifestAndStagedPhoto() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-moment-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.jpg")
        try Data(repeating: 0x42, count: 1_024).write(to: source)
        let store = AppleMomentStore(vaultRootURL: root)
        let draftID = try await store.saveDraft(
            title: "Reject me",
            occurredAt: Date(),
            contactReferenceHashes: [String(repeating: "a", count: 64)],
            photoFileURL: source,
            photoFileExtension: "jpg"
        )
        let manifest = root.appendingPathComponent(
            "_agent/system-actions/moments/\(draftID.uuidString.lowercased()).json"
        )
        let photo = root.appendingPathComponent(
            "_agent/system-actions/moments/assets/\(draftID.uuidString.lowercased()).jpg"
        )
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(FileManager.default.fileExists(atPath: photo.path))

        try await store.discardDraft(id: draftID)

        #expect(!FileManager.default.fileExists(atPath: manifest.path))
        #expect(!FileManager.default.fileExists(atPath: photo.path))
    }

    @Test func momentDraftRejectsNonASCIIContactHashes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-moment-hash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleMomentStore(vaultRootURL: root)

        for nonASCIIHash in [
            String(repeating: "١", count: 64),
            String(repeating: "１", count: 64),
        ] {
            await #expect(throws: (any Error).self) {
                try await store.saveDraft(
                    title: "Moment",
                    occurredAt: Date(),
                    contactReferenceHashes: [nonASCIIHash],
                    photoFileURL: nil,
                    photoFileExtension: nil
                )
            }
        }
    }

    @Test func captureStoreWritesRecoverableManifestBeforeReturningArtifact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-capture-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceMemoID = UUID()
        let filer = CaptureFilerDouble(sourceMemoID: sourceMemoID)
        let store = SystemActionCaptureStore(vaultRootURL: root, filer: filer)
        let actionID = UUID()
        let artifact = try await store.persist(
            data: Data("hello".utf8),
            request: .init(
                presentationID: UUID(),
                actionID: actionID,
                kind: .text,
                suggestedTitle: "Note",
                attachesToSource: true,
                sourceMemoID: sourceMemoID
            ),
            fileExtension: "txt",
            contentType: "public.plain-text",
            pageCount: nil,
            characterCount: 5,
            pixelWidth: nil,
            pixelHeight: nil
        )
        let recent = await store.recent()
        let record = try #require(recent.first)
        let storedFileURL = await store.fileURL(for: record)

        #expect(record.actionID == actionID)
        #expect(record.relativePath == artifact.relativePath)
        #expect(record.contentSHA256 == SystemActionFileDigest.sha256(data: Data("hello".utf8)))
        #expect(record.filedMemoID == nil)
        #expect(record.sourceMemoID == sourceMemoID)
        #expect(FileManager.default.fileExists(atPath: storedFileURL.path))

        let attachedMemoID = try await store.fileToSourceMemo(id: record.id)
        let afterSourceFiling = await store.recent()
        let attachedRecord = try #require(afterSourceFiling.first)
        #expect(attachedMemoID == sourceMemoID)
        #expect(attachedRecord.filedMemoID == sourceMemoID)
        #expect(attachedRecord.filedDestination == .sourceMemo)
        #expect(filer.sourceFilingCount == 1)

        try await store.discard(id: record.id)
        let afterDiscard = await store.recent()
        #expect(afterDiscard.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storedFileURL.path))

        _ = try await store.persist(
            data: Data("second".utf8),
            request: .init(
                presentationID: UUID(),
                actionID: UUID(),
                kind: .file,
                suggestedTitle: "Second",
                attachesToSource: false
            ),
            fileExtension: "txt",
            contentType: "public.plain-text",
            pageCount: nil,
            characterCount: 6,
            pixelWidth: nil,
            pixelHeight: nil
        )
        let beforeNewMemoFiling = await store.recent()
        let secondRecord = try #require(beforeNewMemoFiling.first)
        let newMemoID = try await store.fileAsNewMemo(id: secondRecord.id)
        let afterNewMemoFiling = await store.recent()
        #expect(newMemoID == secondRecord.id)
        #expect(afterNewMemoFiling.first?.filedDestination == .newMemo)
        #expect(filer.newMemoFilingCount == 1)
        try await store.clearAll()
        let afterClear = await store.recent()
        #expect(afterClear.isEmpty)
    }

    @Test func captureStoreRejectsSameLengthContentReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-capture-integrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SystemActionCaptureStore(
            vaultRootURL: root,
            filer: CaptureFilerDouble(sourceMemoID: UUID())
        )
        _ = try await store.persist(
            data: Data("hello".utf8),
            request: .init(
                presentationID: UUID(),
                actionID: UUID(),
                kind: .text,
                suggestedTitle: nil,
                attachesToSource: false
            ),
            fileExtension: "txt",
            contentType: "public.plain-text",
            pageCount: nil,
            characterCount: 5,
            pixelWidth: nil,
            pixelHeight: nil
        )
        let record = try #require(await store.recent().first)
        let fileURL = await store.fileURL(for: record)
        try Data("world".utf8).write(to: fileURL, options: .atomic)

        let recordsAfterReplacement = await store.recent()
        #expect(recordsAfterReplacement.isEmpty)
        await #expect(throws: CocoaError.self) {
            _ = try await store.fileAsNewMemo(id: record.id)
        }
    }

    private func reminderProposal() throws -> SystemActionProposal {
        try SystemActionProposal(
            payload: .reminder(.init(title: "Initial")),
            title: "Initial",
            rationale: "Before edit",
            creatorSource: .user,
            creatorDeviceID: "device-a"
        )
    }

    private func makeModel(
        prepareAccountBoundary: @escaping @Sendable () async throws -> Void = {}
    ) -> SystemActionCenterModel {
        let ledger = SystemActionLedger(
            vaultRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true),
            deviceID: "device-a"
        )
        let commands = SystemActionCenterCommands(
            save: { _ in },
            replace: { _, _ in },
            approve: { _, _ in },
            reject: { _ in },
            execute: { _ in },
            undo: { _ in },
            capabilitySnapshots: { [] },
            setCapabilityPolicy: { _ in },
            sync: {},
            prepareAccountBoundary: prepareAccountBoundary,
            publishSystemSummaries: { _ in }
        )
        return SystemActionCenterModel(ledger: ledger, deviceID: "device-a", commands: commands)
    }
}
}

private final class CaptureFilerDouble: SystemActionCaptureFiling, @unchecked Sendable {
    let sourceMemoID: UUID
    private(set) var sourceFilingCount = 0
    private(set) var newMemoFilingCount = 0

    init(sourceMemoID: UUID) {
        self.sourceMemoID = sourceMemoID
    }

    func fileAsNewMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID {
        newMemoFilingCount += 1
        return record.id
    }

    func attachToSourceMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID {
        sourceFilingCount += 1
        guard record.sourceMemoID == sourceMemoID else {
            throw CocoaError(.fileNoSuchFile)
        }
        return sourceMemoID
    }
}

private struct UnlocalizedTestFailure: Error {}

private actor AccountIDBox {
    private var accountID: String?
    init(_ accountID: String?) { self.accountID = accountID }
    func value() -> String? { accountID }
    func set(_ value: String?) { accountID = value }
}

private actor AsyncCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}


// MARK: - DayPageSerialSwiftTests namespace aliases (preserve global names for helpers,
// extensions, and qualified references after the serialized-root move)
typealias SystemActionUIModelTests = DayPageSerialSwiftTests.SystemActionUIModelTests
