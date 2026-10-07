import XCTest
@testable import DayPageServices

/// Flomo-native refinement — 洞察视角（insight strategy）本地偏好存储与校验。
///
/// 覆盖：
/// - 内置策略的稳定 ID（UI / 测试 / 迁移都不许依赖本地化标题）。
/// - trim + 空值 + 长度校验。
/// - 注入式 UserDefaults 的真实持久化（建 / 改 / 删 / 选择）。
/// - 删除已选中的自定义策略后回退默认内置策略（reset fallback）。
/// - 默认值里只存 title + instructions + 选择 ID —— 不存 memo 正文、
///   证据或凭据。
final class InsightStrategyTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "InsightStrategyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Builtins

    func test_builtinStrategies_haveStableUniqueIDs() {
        let ids = InsightStrategy.builtinStrategies.map(\.id)
        XCTAssertEqual(ids, [
            InsightStrategy.patternsID,
            InsightStrategy.challengeAssumptionID,
            InsightStrategy.nextSmallStepID,
        ])
        XCTAssertEqual(Set(ids).count, ids.count, "builtin IDs must be unique")
        XCTAssertTrue(InsightStrategy.builtinStrategies.allSatisfy { $0.isBuiltin })
        XCTAssertTrue(InsightStrategy.builtinStrategies.allSatisfy {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.instructions.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }

    func test_defaultStrategy_isFirstBuiltin() {
        XCTAssertEqual(InsightStrategy.defaultStrategy.id, InsightStrategy.patternsID)
    }

    // MARK: - Validation

    func test_draft_trimsWhitespace() throws {
        let (title, instructions) = try InsightStrategyDraft.validated(
            title: "  视角  ", instructions: "\n 看重复出现的主题 \n"
        )
        XCTAssertEqual(title, "视角")
        XCTAssertEqual(instructions, "看重复出现的主题")
    }

    func test_draft_rejectsEmptyAfterTrim() {
        XCTAssertThrowsError(try InsightStrategyDraft.validated(title: "   ", instructions: "ok")) { error in
            XCTAssertEqual(error as? InsightStrategyValidationError, .emptyTitle)
        }
        XCTAssertThrowsError(try InsightStrategyDraft.validated(title: "ok", instructions: "\n\t")) { error in
            XCTAssertEqual(error as? InsightStrategyValidationError, .emptyInstructions)
        }
    }

    func test_draft_rejectsOverlong() {
        let longTitle = String(repeating: "题", count: InsightStrategy.maxTitleLength + 1)
        XCTAssertThrowsError(try InsightStrategyDraft.validated(title: longTitle, instructions: "ok")) { error in
            XCTAssertEqual(error as? InsightStrategyValidationError, .titleTooLong)
        }
        let longBody = String(repeating: "字", count: InsightStrategy.maxInstructionsLength + 1)
        XCTAssertThrowsError(try InsightStrategyDraft.validated(title: "ok", instructions: longBody)) { error in
            XCTAssertEqual(error as? InsightStrategyValidationError, .instructionsTooLong)
        }
    }

    // MARK: - Store lifecycle (injected UserDefaults)

    @MainActor
    func test_store_persistsCustomStrategyAcrossInstances() throws {
        let store = InsightStrategyStore(defaults: defaults)
        let saved = try store.saveCustom(title: "看情绪变化", instructions: "关注这条记录前后情绪的走向")
        XCTAssertTrue(saved.isBuiltin == false)

        let reloaded = InsightStrategyStore(defaults: defaults)
        XCTAssertEqual(reloaded.customStrategies.map(\.id), [saved.id])
        XCTAssertEqual(reloaded.customStrategies.first?.title, "看情绪变化")
    }

    @MainActor
    func test_store_editUpdatesInPlace() throws {
        let store = InsightStrategyStore(defaults: defaults)
        let saved = try store.saveCustom(title: "旧标题", instructions: "旧指令")
        try store.saveCustom(id: saved.id, title: "新标题", instructions: "新指令")

        XCTAssertEqual(store.customStrategies.count, 1)
        XCTAssertEqual(store.customStrategies.first?.title, "新标题")
        XCTAssertEqual(store.customStrategies.first?.instructions, "新指令")
    }

    @MainActor
    func test_store_selectionPersists_andUnknownIDIsIgnored() throws {
        let store = InsightStrategyStore(defaults: defaults)
        let saved = try store.saveCustom(title: "视角", instructions: "指令")
        XCTAssertTrue(store.select(saved.id))
        XCTAssertEqual(store.selectedStrategy.id, saved.id)

        // Unknown IDs must not move the selection.
        XCTAssertFalse(store.select("builtin.missing"))
        XCTAssertEqual(store.selectedStrategy.id, saved.id)

        let reloaded = InsightStrategyStore(defaults: defaults)
        XCTAssertEqual(reloaded.selectedStrategy.id, saved.id)
    }

    @MainActor
    func test_deleteSelectedCustom_resetsToDefaultBuiltin() throws {
        let store = InsightStrategyStore(defaults: defaults)
        let saved = try store.saveCustom(title: "视角", instructions: "指令")
        store.select(saved.id)

        store.deleteCustom(id: saved.id)
        XCTAssertTrue(store.customStrategies.isEmpty)
        XCTAssertEqual(store.selectedStrategy.id, InsightStrategy.patternsID)
        // The fallback is persisted, not just in-memory.
        XCTAssertEqual(
            defaults.string(forKey: InsightStrategyStore.selectedStrategyKey),
            InsightStrategy.patternsID
        )
    }

    @MainActor
    func test_store_repairsDanglingSelectionOnInit() throws {
        defaults.set("custom.gone", forKey: InsightStrategyStore.selectedStrategyKey)
        let store = InsightStrategyStore(defaults: defaults)
        XCTAssertEqual(store.selectedStrategy.id, InsightStrategy.patternsID)
        XCTAssertEqual(defaults.string(forKey: InsightStrategyStore.selectedStrategyKey), InsightStrategy.patternsID)
    }

    @MainActor
    func test_deleteBuiltinID_isIgnored() {
        let store = InsightStrategyStore(defaults: defaults)
        store.deleteCustom(id: InsightStrategy.patternsID)
        XCTAssertEqual(store.allStrategies.count, InsightStrategy.builtinStrategies.count)
    }

    // MARK: - Defaults payload discipline

    @MainActor
    func test_defaultsOnlyContainStrategyTextAndSelectionID() throws {
        let store = InsightStrategyStore(defaults: defaults)
        let saved = try store.saveCustom(title: "视角", instructions: "指令")
        store.select(saved.id)

        guard let data = defaults.data(forKey: InsightStrategyStore.customStrategiesKey) else {
            return XCTFail("custom strategies must persist as JSON data")
        }
        // Decode through plain Codable keys — title/instructions only. If a
        // future change smuggles memo bodies or evidence into the payload the
        // extra keys would surface here as unknown fields.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for entry in raw {
            XCTAssertEqual(Set(entry.keys), ["id", "title", "instructions", "kind"])
        }
    }

    // MARK: - Composition

    func test_composedInstruction_isUserLevelText() {
        let strategy = InsightStrategy(id: "x", title: "视角", instructions: "指令")
        let text = strategy.composedInstruction()
        XCTAssertTrue(text.contains("视角"))
        XCTAssertTrue(text.contains("指令"))
    }
}
