import SwiftUI

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
            onTap(template)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DSColor.inkSubtle)
                    .padding(.trailing, 6)

                Text(template.prefix)
                    .font(DSType.serifBody16)
                    .foregroundStyle(DSColor.inkMuted)
                + Text(template.placeholder)
                    .font(DSType.serifBody16)
                    .foregroundStyle(DSColor.inkSubtle)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模板：\(template.display)")
        .accessibilityHint("点击将模板填入输入框")
    }
}
