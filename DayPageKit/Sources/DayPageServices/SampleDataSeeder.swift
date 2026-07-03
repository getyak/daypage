import Foundation
import DayPageModels
import DayPageStorage

// MARK: - SampleDataSeeder

/// Seeds 3 sample memos on first launch after onboarding.
/// Memos are written to vault/raw/{yesterday}.md.
public enum SampleDataSeeder {

    private static let seededKey = "hasSeededSamples"

    // MARK: - Public API

    public static func seedIfNeeded() {
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

            // Issue #2 (2026-07-02): also seed a pre-compiled daily page for
            // yesterday, so a first-time user who taps "See a sample journal"
            // instantly sees the AI output — not just three raw memos with a
            // silent "AI will compile tonight" promise. Without this, the
            // user has to wait for BGTaskScheduler to fire at 02:00 to see
            // what the product actually does, which is the exact "空状态不
            // 知道会得到什么" gap Issue #2 targets. The file is written to
            // the same path CompilationService uses so the Daily page reads
            // it verbatim.
            try? writeSampleDailyPage(for: yesterday)

            UserDefaults.standard.set(true, forKey: seededKey)
        } catch {
            Task { @MainActor in DayPageLogger.shared.error("SampleDataSeeder: seed failed: \(error)") }
        }
    }

    private static func writeSampleDailyPage(for date: Date) throws {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let dateString = df.string(from: date)

        let dailyURL = VaultInitializer.vaultURL
            .appendingPathComponent("wiki")
            .appendingPathComponent("daily")
            .appendingPathComponent("\(dateString).md")

        // Skip if a real compiled daily already exists — don't clobber user
        // work if seedIfNeeded is (re-)invoked after a crash or manual reset.
        if FileManager.default.fileExists(atPath: dailyURL.path) { return }

        try FileManager.default.createDirectory(
            at: dailyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Sample daily.md carries Issue #4 evidence markers so a first-time
        // user who taps "See a sample journal" sees "引用 N 条" chips wired
        // up to real sample memos on first look, not an empty promise.
        let body = """
        ---
        type: daily
        date: \(dateString)
        source: sample
        ---

        # \(dateString) · 咖啡店的雨与新工作流

        雨天从咖啡店开始，午间冒出一个想把念头「先倒进 DayPage、晚上再整理」的
        工作流念头，午后在街角捕到一束好光——三条看似松散的记录，被 AI 编成
        一天里悄悄推进的一件事：**给自己造一个更松弛的记录节奏**。

        ## 主题
        - **地点情绪**：雨中的 [[咖啡店]] 是今天的思考容器。[^m:\(memo1Id)]
        - **工作流实验**：想让 [[DayPage]] 承担"先倒进来"的角色。[^m:\(memo2Id)]
        - **街景光线**：[[街角]] 那束光成了今天的视觉锚点。[^m:\(memo3Id)]

        ## 引用
        > 在咖啡店角落的位置，窗外在下小雨。 — 上午 09:00
        > 今天想试试新的工作流，把所有想法先倒进 DayPage，晚上再整理。 — 中午 12:00
        > 路过这里，光线很好。 — 下午 15:00

        ## 建议明天试试
        - 早起后再来这家咖啡店，把昨天的念头写成一段更完整的想法。
        - 用 DayPage 的每周复盘题，检验"先倒进来再整理"是否真的更松弛。
        """

        try body.data(using: .utf8)?.write(to: dailyURL, options: .atomic)
    }

    // MARK: - Clear sample data

    public static func clearSampleData() {
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

            // Issue #2 (2026-07-02): also remove the paired sample daily.md
            // we wrote in seedIfNeeded. Only remove if it still carries the
            // `source: sample` frontmatter — never clobber a real compiled
            // daily the user has since produced.
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.timeZone = TimeZone(identifier: "UTC")
            let dailyURL = VaultInitializer.vaultURL
                .appendingPathComponent("wiki")
                .appendingPathComponent("daily")
                .appendingPathComponent("\(df.string(from: yesterday)).md")
            if let content = try? String(contentsOf: dailyURL, encoding: .utf8),
               content.contains("source: sample") {
                try? FileManager.default.removeItem(at: dailyURL)
            }

            UserDefaults.standard.set(false, forKey: seededKey)
        } catch {
            Task { @MainActor in DayPageLogger.shared.error("SampleDataSeeder: clear failed: \(error)") }
        }
    }

    public static var hasSeededSamples: Bool {
        UserDefaults.standard.bool(forKey: seededKey)
    }

    // MARK: - Private

    // Sample memo IDs. RFC-4122 v4-shaped so `UUID(uuidString:)` accepts
    // them verbatim — the previous "SAMPLE-…" strings fell through the
    // guard and got replaced with fresh random UUIDs each seed run, which
    // broke Issue #4's `[^m:<uuid>]` evidence links in the sample daily.
    // The `da97a9e` byte pattern is deliberately not a well-known service
    // UUID; it just marks these three as sample rows for tooling filters
    // (matches `sampleMemoIds` set).
    private static let memo1Id = "DA97A9E1-0000-4000-8000-000000000001"
    private static let memo2Id = "DA97A9E2-0000-4000-8000-000000000002"
    private static let memo3Id = "DA97A9E3-0000-4000-8000-000000000003"

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
