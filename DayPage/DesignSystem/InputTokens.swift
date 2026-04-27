import SwiftUI
import UIKit

// MARK: - InputTokens
//
// Centralized thresholds and haptic intensities for the press-to-talk
// interaction (US-008). Keeping them here lets the overlay view, gesture
// handler and any future tuning surface consume the same constants.

enum InputTokens {

    // MARK: - Press-to-Talk Gesture

    /// 触发"取消"状态所需的最小垂直向上滑动距离（以点为单位）。
    /// 从 80pt 降低到 60pt：可用性测试表明 80pt 在大多数手机上需要
    /// 别扭的拇指伸展；60pt 舒适且能防止意外触发。
    static let cancelSwipeThreshold: CGFloat = 60

    /// 触发"仅转写"状态所需的最小左滑距离（以点为单位）。
    /// 从 80pt 降低到 60pt 以匹配 cancelSwipeThreshold。
    static let transcribeSwipeThreshold: CGFloat = 60

    // MARK: - Haptic Intensities

    /// 按下时触发（录音开始）。
    static let pressDownHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .light

    /// 原位释放时触发（立即发送）。
    static let sendReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium

    /// 拖动进入取消预备区域时触发。
    static let cancelArmHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .heavy

    /// 拖动进入转写预备区域时触发。
    static let transcribeArmHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium

    /// 取消预备手势释放时触发（录音已丢弃）。
    static let cancelReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .light

    /// 转写预备手势释放时触发（文本已填充，未发送）。
    static let transcribeReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium
}
