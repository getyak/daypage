import Foundation

// MARK: - SampleDataSeeder

/// Seeds 3 sample memos on first launch after onboarding.
/// Memos are written to vault/raw/{yesterday}.md.
enum SampleDataSeeder {

    private static let seededKey = "hasSeededSamples"

    // MARK: - Public API

    static func seedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }

        do {
            let existing = (try? RawStorage.read(for: yesterday)) ?? []
            guard existing.isEmpty else {
                UserDefaults.standard.set(true, forKey: seededKey)
                return
            }

            let memos = makeSampleMemos(for: yesterday)
            for memo in memos {
                try RawStorage.append(memo)
            }
            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            Task { @MainActor in DayPageLogger.shared.error("SampleDataSeeder: seed failed: \(error)") }
        }
    }

    // MARK: - Clear sample data

    static func clearSampleData() {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return }

        do {
            let existing = try RawStorage.read(for: yesterday)
            let sampleIds = sampleMemoIds()
            let remaining = existing.filter { !sampleIds.contains($0.id.uuidString) }

            let fileURL = RawStorage.fileURL(for: yesterday)
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
            } else {
                let content = remaining.map { $0.toMarkdown() }.joined(separator: RawStorage.memoSeparator)
                try RawStorage.atomicWrite(string: content, to: fileURL)
            }
            UserDefaults.standard.set(false, forKey: seededKey)
        } catch {
            Task { @MainActor in DayPageLogger.shared.error("SampleDataSeeder: clear failed: \(error)") }
        }
    }

    static var hasSeededSamples: Bool {
        UserDefaults.standard.bool(forKey: seededKey)
    }

    // MARK: - Private

    private static let memo1Id = "SAMPLE-001-0000-0000-000000000001"
    private static let memo2Id = "SAMPLE-002-0000-0000-000000000002"
    private static let memo3Id = "SAMPLE-003-0000-0000-000000000003"

    private static func sampleMemoIds() -> Set<String> {
        [memo1Id, memo2Id, memo3Id]
    }

    private static func makeSampleMemos(for date: Date) -> [Memo] {
        let cal = Calendar.current
        let base = cal.startOfDay(for: date)
        let morning = base.addingTimeInterval(9 * 3600)
        let noon = base.addingTimeInterval(12 * 3600)
        let afternoon = base.addingTimeInterval(15 * 3600)

        // Memo 1: text
        let memo1 = Memo(
            id: UUID(uuidString: memo1Id) ?? UUID(),
            type: .text,
            created: morning,
            location: Memo.Location(name: "咖啡店", lat: 31.2304, lng: 121.4737),
            weather: "小雨 18°C",
            device: "iPhone",
            attachments: [],
            body: "在咖啡店角落的位置，窗外在下小雨。"
        )

        // Memo 2: voice (with transcript, no bundled audio — transcript only)
        let memo2 = Memo(
            id: UUID(uuidString: memo2Id) ?? UUID(),
            type: .voice,
            created: noon,
            location: nil,
            weather: nil,
            device: "iPhone",
            attachments: [
                Memo.Attachment(
                    file: "raw/assets/sample_voice.m4a",
                    kind: "audio",
                    duration: 12.5,
                    transcript: "今天想试试新的工作流，把所有想法先倒进 DayPage，晚上再整理。"
                )
            ],
            body: ""
        )

        // Memo 3: photo (bundled sample)
        let memo3 = Memo(
            id: UUID(uuidString: memo3Id) ?? UUID(),
            type: .photo,
            created: afternoon,
            location: Memo.Location(name: "街角", lat: 31.2310, lng: 121.4740),
            weather: nil,
            device: "iPhone",
            attachments: [
                Memo.Attachment(
                    file: "raw/assets/sample_photo.jpg",
                    kind: "photo",
                    duration: nil,
                    transcript: "aperture=f/1.8 shutter=1/120 ISO=100"
                )
            ],
            body: "路过这里，光线很好。"
        )

        return [memo1, memo2, memo3]
    }
}
