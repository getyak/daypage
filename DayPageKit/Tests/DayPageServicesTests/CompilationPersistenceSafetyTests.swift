import Foundation
import Testing
@testable import DayPageModels
@testable import DayPageServices
@testable import DayPageStorage

private func makeCompilationSafetyVault() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("compilation-safety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Suite("Compilation persistence safety", .serialized)
struct CompilationPersistenceSafetyTests {

    @Test @MainActor
    func replayingEntityInstructionIsIdempotent() throws {
        let root = try makeCompilationSafetyVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = EntityPageService(vaultRootOverride: root)
        let instruction = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: "joma-coffee",
            section: "## Visits",
            content: """
            - 2026-08-07: Had an Americano
              - Worked on DayPage
            """,
            displayName: "Joma Coffee"
        )

        try service.apply(instructions: [instruction], date: "2026-08-07")
        let entityURL = root.appendingPathComponent("wiki/places/joma-coffee.md")
        let firstWrite = try String(contentsOf: entityURL, encoding: .utf8)

        try service.apply(instructions: [instruction], date: "2026-08-07")
        let replayed = try String(contentsOf: entityURL, encoding: .utf8)

        #expect(replayed == firstWrite)
        #expect(replayed.contains("occurrence_count: 1"))
        #expect(replayed.components(separatedBy: instruction.content).count - 1 == 1)
    }

    @Test
    func forceOperationIDIsStablePerDailyRevisionAndAdvancesAfterRevisionChange() {
        let sourceHash = "same-raw-source"
        let normalAtRevisionA = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: false,
            existingDailyRevision: "daily-revision-a"
        )
        let normalAtRevisionB = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: false,
            existingDailyRevision: "daily-revision-b"
        )
        let forceAtRevisionA = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: true,
            existingDailyRevision: "daily-revision-a"
        )
        let retryAtRevisionA = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: true,
            existingDailyRevision: "daily-revision-a"
        )
        let forceAtRevisionB = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: true,
            existingDailyRevision: "daily-revision-b"
        )

        #expect(normalAtRevisionA == sourceHash)
        #expect(normalAtRevisionB == sourceHash)
        #expect(forceAtRevisionA == retryAtRevisionA)
        #expect(forceAtRevisionA != forceAtRevisionB)
    }

    @Test
    func dailyPageRevisionAdvancesAfterAtomicReplacement() throws {
        let root = try makeCompilationSafetyVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let dailyURL = root.appendingPathComponent("wiki/daily/2026-08-07.md")
        try RawStorage.atomicWrite(
            string: "---\ntype: daily\n---\n\n# First\n",
            to: dailyURL
        )
        let firstRevision = CompilationService.dailyPageRevision(at: dailyURL)

        try RawStorage.atomicWrite(
            string: "---\ntype: daily\n---\n\n# Forced replacement\n",
            to: dailyURL
        )
        let secondRevision = CompilationService.dailyPageRevision(at: dailyURL)
        let persisted = try String(contentsOf: dailyURL, encoding: .utf8)

        #expect(firstRevision != "missing")
        #expect(secondRevision != "missing")
        #expect(secondRevision != firstRevision)
        #expect(persisted.contains("# Forced replacement"))
    }

    @Test @MainActor
    func sameOperationWithDifferentWordingIsExactlyOncePerEntityPage() throws {
        let root = try makeCompilationSafetyVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = EntityPageService(vaultRootOverride: root)
        let sourceHash = "same-raw-source"
        let firstForceOperationID = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: true,
            existingDailyRevision: "daily-revision-a"
        )
        let nextForceOperationID = CompilationService.entityOperationID(
            sourceHash: sourceHash,
            force: true,
            existingDailyRevision: "daily-revision-b"
        )
        let first = EntityUpdateInstruction(
            entityType: "themes",
            entitySlug: "focused-work",
            section: "## Observations",
            content: "- Protected a quiet morning for focused work.",
            displayName: "Focused Work"
        )
        let retryWithDifferentWording = EntityUpdateInstruction(
            entityType: "themes",
            entitySlug: "focused-work",
            section: "## Observations",
            content: "- Reserved the morning for uninterrupted deep work.",
            displayName: "Focused Work"
        )

        try service.apply(
            instructions: [first],
            date: "2026-08-07",
            operationID: firstForceOperationID
        )
        let entityURL = root.appendingPathComponent("wiki/themes/focused-work.md")
        let firstWrite = try String(contentsOf: entityURL, encoding: .utf8)

        try service.apply(
            instructions: [retryWithDifferentWording],
            date: "2026-08-07",
            operationID: firstForceOperationID
        )
        let sameOperationRetry = try String(contentsOf: entityURL, encoding: .utf8)

        #expect(sameOperationRetry == firstWrite)
        #expect(sameOperationRetry.contains("occurrence_count: 1"))
        #expect(!sameOperationRetry.contains(retryWithDifferentWording.content))
        #expect(
            sameOperationRetry
                .components(
                    separatedBy: "<!-- daypage-compilation:\(firstForceOperationID) -->"
                )
                .count - 1 == 1
        )

        try service.apply(
            instructions: [retryWithDifferentWording],
            date: "2026-08-08",
            operationID: nextForceOperationID
        )
        let differentOperation = try String(contentsOf: entityURL, encoding: .utf8)

        #expect(differentOperation.contains("occurrence_count: 2"))
        #expect(differentOperation.contains(retryWithDifferentWording.content))
        #expect(
            differentOperation.contains(
                "<!-- daypage-compilation:\(nextForceOperationID) -->"
            )
        )
    }

    @Test @MainActor
    func oneOperationPersistsAllInstructionsForSameEntityPage() throws {
        let root = try makeCompilationSafetyVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = EntityPageService(vaultRootOverride: root)
        let visit = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: "joma-coffee",
            section: "## Visits",
            content: "- 2026-08-07: Morning work session.",
            displayName: "Joma Coffee"
        )
        let detail = EntityUpdateInstruction(
            entityType: "places",
            entitySlug: "joma-coffee",
            section: "## Notes",
            content: "- The upstairs table was quiet.",
            displayName: "Joma Coffee"
        )

        try service.apply(
            instructions: [visit, detail],
            date: "2026-08-07",
            operationID: "source-hash-grouped"
        )

        let entityURL = root.appendingPathComponent("wiki/places/joma-coffee.md")
        let page = try String(contentsOf: entityURL, encoding: .utf8)
        #expect(page.contains(visit.content))
        #expect(page.contains(detail.content))
        #expect(page.contains("occurrence_count: 2"))
        #expect(
            page
                .components(separatedBy: "<!-- daypage-compilation:source-hash-grouped -->")
                .count - 1 == 1
        )
    }

    @Test @MainActor
    func retryReconcilesMissingIndexAfterPageMarkerCommitted() throws {
        let root = try makeCompilationSafetyVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = EntityPageService(vaultRootOverride: root)
        let first = EntityUpdateInstruction(
            entityType: "people",
            entitySlug: "alice",
            section: "## Encounters",
            content: "- 2026-08-07: Planned the next milestone.",
            displayName: "Alice"
        )
        let retryWithDifferentWording = EntityUpdateInstruction(
            entityType: "people",
            entitySlug: "alice",
            section: "## Encounters",
            content: "- 2026-08-07: Discussed what to build next.",
            displayName: "Alice (retry wording)"
        )

        try service.apply(
            instructions: [first],
            date: "2026-08-07",
            operationID: "source-hash-index-recovery"
        )

        let entityURL = root.appendingPathComponent("wiki/people/alice.md")
        let pageBeforeIndexLoss = try String(contentsOf: entityURL, encoding: .utf8)
        #expect(pageBeforeIndexLoss.contains("occurrence_count: 1"))
        #expect(
            pageBeforeIndexLoss.contains(
                "<!-- daypage-compilation:source-hash-index-recovery -->"
            )
        )

        let indexURL = root.appendingPathComponent("wiki/index.md")
        try FileManager.default.removeItem(at: indexURL)
        try service.apply(
            instructions: [retryWithDifferentWording],
            date: "2026-08-07",
            operationID: "source-hash-index-recovery"
        )

        let pageAfterRecovery = try String(contentsOf: entityURL, encoding: .utf8)
        let indexAfterRecovery = try String(
            contentsOf: indexURL,
            encoding: .utf8
        )
        let expectedIndexItem = "- [[wiki/people/alice|Alice]]"

        #expect(pageAfterRecovery == pageBeforeIndexLoss)
        #expect(!pageAfterRecovery.contains(retryWithDifferentWording.content))
        #expect(indexAfterRecovery.components(separatedBy: expectedIndexItem).count - 1 == 1)

        try service.apply(
            instructions: [retryWithDifferentWording],
            date: "2026-08-07",
            operationID: "source-hash-index-recovery"
        )
        let indexAfterSecondRetry = try String(
            contentsOf: indexURL,
            encoding: .utf8
        )
        #expect(indexAfterSecondRetry == indexAfterRecovery)
    }

    @Test @MainActor
    func memoBackfillMutatesCurrentDayFileAndPostsWriteNotification() throws {
        let root = try makeCompilationSafetyVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }
        VaultInitializer.testOverrideURL = root
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("raw"),
            withIntermediateDirectories: true
        )

        let dateString = "2026-08-07"
        let date = try #require(ISO8601DateFormatter.dayOnly.date(from: dateString))
        let target = Memo(id: UUID(), created: date, body: "Target")
        let untouched = Memo(id: UUID(), created: date.addingTimeInterval(60), body: "Untouched")
        try RawStorage.rewrite([target, untouched], for: date)

        var didNotify = false
        let observer = NotificationCenter.default.addObserver(
            forName: .rawStorageDidWrite,
            object: nil,
            queue: nil
        ) { notification in
            guard let writtenDate = notification.object as? Date,
                  ISO8601DateFormatter.dayOnly.string(from: writtenDate) == dateString else { return }
            didNotify = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let update = CompilationService.MemoUpdateInstruction(
            memoID: target.id,
            mood: "focused",
            entityMentions: ["Joma Coffee"],
            dateReferences: [],
            marginNote: "A useful pattern."
        )
        let result = CompilationService.shared.applyMemoUpdates(
            [update],
            dateString: dateString
        )
        let persisted = try RawStorage.read(for: date)

        #expect(result.updated == 1)
        #expect(result.failed == 0)
        #expect(didNotify)
        #expect(persisted.count == 2)
        #expect(persisted.first(where: { $0.id == target.id })?.mood == "focused")
        #expect(persisted.first(where: { $0.id == target.id })?.entityMentions == ["Joma Coffee"])
        #expect(persisted.first(where: { $0.id == target.id })?.marginNote == "A useful pattern.")
        #expect(persisted.first(where: { $0.id == untouched.id })?.body == "Untouched")
    }

    @Test @MainActor
    func entityFailureDoesNotWriteSourceHashCompletionMarker() async throws {
        let root = try makeCompilationSafetyVault()
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }
        VaultInitializer.testOverrideURL = root

        let dailyDirectory = root.appendingPathComponent("wiki/daily", isDirectory: true)
        let memo = Memo(created: Date(timeIntervalSince1970: 1_786_060_800), body: "Synthetic compilation input")
        try RawStorage.atomicWrite(string: memo.toMarkdown(), to: root.appendingPathComponent("raw/2026-08-07.md"))
        let service = CompilationService(vaultRootProvider: { root }, scope: LocalCompilationCommitScope(), consent: AllowAllAIConsent())
        try FileManager.default.createDirectory(at: dailyDirectory, withIntermediateDirectories: true)
        let dailyURL = dailyDirectory.appendingPathComponent("2026-08-07.md")
        let previousDaily = """
        ---
        type: daily
        source_hash: previous-hash
        ---

        # Previous
        """
        try previousDaily.write(to: dailyURL, atomically: true, encoding: .utf8)

        // A regular file where the entity directory must be forces the
        // throwable entity apply to fail before the daily completion marker.
        let blockedEntityDirectory = root.appendingPathComponent("wiki/places")
        try Data("blocked".utf8).write(to: blockedEntityDirectory)

        let parsed = CompilationService.ParsedCompilationOutput(
            dailyPageText: """
            ---
            type: daily
            ---

            # New
            """,
            entityInstructions: [
                EntityUpdateInstruction(
                    entityType: "places",
                    entitySlug: "joma-coffee",
                    section: "## Visits",
                    content: "- 2026-08-07: Visit",
                    displayName: "Joma Coffee"
                )
            ],
            memoUpdates: [],
            hotCacheText: ""
        )

        await #expect(throws: (any Error).self) {
            try await service.saveResults(
                parsed,
                dateString: "2026-08-07",
                trigger: "test",
                startTime: Date(),
                memoCount: 1,
                sourceHash: CompilationService.sourceHash(of: [memo]),
                entityOperationID: "new-hash"
            )
        }

        let persistedDaily = try String(contentsOf: dailyURL, encoding: .utf8)
        #expect(persistedDaily == previousDaily)
        #expect(CompilationService.extractSourceHash(from: persistedDaily) == "previous-hash")
    }
}
