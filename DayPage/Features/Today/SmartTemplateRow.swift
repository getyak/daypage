import SwiftUI
import DayPageServices

// MARK: - US-015: Smart Templates (12 hardcoded time-slot templates)

struct SmartTemplate {
    /// Prefix inserted into the TextField as real text.
    let prefix: String
    /// Placeholder shown in secondary color; disappears when the user types.
    let placeholder: String

    /// Full display text shown in the template row.
    var display: String { prefix + placeholder }

    // MARK: - Time-slot selection

    static func current() -> SmartTemplate {
        let hour = Calendar.current.component(.hour, from: Date())
        let pool: [SmartTemplate]
        switch hour {
        case 6..<11:  pool = morning
        case 11..<17: pool = afternoon
        case 17..<22: pool = evening
        default:      pool = night
        }
        // Deterministic rotation: changes every 10 minutes so the same
        // session doesn't keep reshuffling, but a new open feels fresh.
        let bucket = (Calendar.current.component(.minute, from: Date())) / 10
        return pool[bucket % pool.count]
    }

    // MARK: - Pools (3 per slot = 12 total, as per AC)

    static let morning: [SmartTemplate] = [
        SmartTemplate(prefix: "今天打算", placeholder: "…"),
        SmartTemplate(prefix: "醒来发现", placeholder: "…"),
        SmartTemplate(prefix: "早上第一件事：", placeholder: ""),
    ]

    static let afternoon: [SmartTemplate] = [
        SmartTemplate(prefix: "刚才", placeholder: "，记一下"),
        SmartTemplate(prefix: "中午", placeholder: "，吃了/见了/想到了…"),
        SmartTemplate(prefix: "一个想法：", placeholder: ""),
    ]

    static let evening: [SmartTemplate] = [
        SmartTemplate(prefix: "今天最", placeholder: "的一刻是"),
        SmartTemplate(prefix: "总结一下今天：", placeholder: ""),
        SmartTemplate(prefix: "明天要记得", placeholder: "…"),
    ]

    static let night: [SmartTemplate] = [
        SmartTemplate(prefix: "回看今天，", placeholder: ""),
        SmartTemplate(prefix: "还没完成的：", placeholder: ""),
        SmartTemplate(prefix: "梦见了", placeholder: "…"),
    ]

    // MARK: - Issue #17 (2026-07-03) · 主题模板池
    //
    // 4 个 time-slot pool 之外，我们再加 3 个 "情境" pool（情绪 / 旅行 /
    // 健康）让 backlog #17 提到的五主题成型：morning + evening 已是通用
    // 起手模板，本次补齐 mood/travel/health.

    static let mood: [SmartTemplate] = [
        SmartTemplate(prefix: "现在的情绪是", placeholder: "…"),
        SmartTemplate(prefix: "有点", placeholder: "，因为"),
        SmartTemplate(prefix: "让我感觉最强烈的是", placeholder: "…"),
    ]

    static let travel: [SmartTemplate] = [
        SmartTemplate(prefix: "抵达", placeholder: "，第一印象是"),
        SmartTemplate(prefix: "路上", placeholder: "…"),
        SmartTemplate(prefix: "这个地方让我", placeholder: "…"),
    ]

    static let health: [SmartTemplate] = [
        SmartTemplate(prefix: "身体状态：", placeholder: ""),
        SmartTemplate(prefix: "睡了", placeholder: "小时，感觉…"),
        SmartTemplate(prefix: "今天运动/饮食：", placeholder: ""),
    ]
}

// MARK: - SmartTemplateRow

/// One-line template hint shown inside the composer card when text and
/// attachments are both empty. Tapping fills the TextField with the
/// template prefix and shows the placeholder in secondary color.
struct SmartTemplateRow: View {

    let template: SmartTemplate
    var onTap: (SmartTemplate) -> Void

    var body: some View {
        Button {
            Haptics.soft()
            onTap(template)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSColor.inkSubtle)
                    .padding(.trailing, 6)

                Text(template.prefix)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkMuted)
                + Text(template.placeholder)
                    .font(DSType.serifBody16)
                    .foregroundColor(DSColor.inkMuted)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .pressScale(scale: 0.97, animation: Motion.spring)
        .accessibilityLabel("模板：\(template.display)")
        .accessibilityHint("点击将模板填入输入框")
    }
}

