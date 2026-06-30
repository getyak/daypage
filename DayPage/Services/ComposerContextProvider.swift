import Foundation
import UIKit
import DayPageModels
import DayPageServices

// MARK: - ContextChip

enum ContextChip: Identifiable, Equatable {
    case weather(temp: String, condition: String)
    /// Carries `lat`/`lng` so chips reuse the user's real coordinates instead
    /// of silently nil-ing them (#254 review feedback).
    case location(short: String, lat: Double?, lng: Double?)
    case timeRitual(emoji: String, text: String)
    case lastMemoTail(snippet: String)
    /// Pasteboard chip is an *opaque availability signal*: it indicates the
    /// system pasteboard has text without reading the contents, so SwiftUI
    /// re-renders no longer trigger the "Pasted from <other app>" iOS banner
    /// or silently load secrets. The actual `.string` is read only when the
    /// user explicitly taps the chip (see `SpotlightStripView.applyChip`).
    case smartPaste

    var id: String {
        switch self {
        case .weather(let temp, let condition): return "weather-\(temp)-\(condition)"
        case .location(let short, _, _): return "location-\(short)"
        case .timeRitual(let emoji, let text): return "ritual-\(emoji)-\(text)"
        case .lastMemoTail(let snippet): return "lastMemo-\(snippet.prefix(20))"
        case .smartPaste: return "paste-available"
        }
    }
}

// MARK: - ComposerContextProvider

@MainActor
final class ComposerContextProvider: ObservableObject {

    // MARK: Singleton

    static let shared = ComposerContextProvider()

    // MARK: Dependencies

    private let weatherService: WeatherService
    private let locationService: LocationService

    // MARK: Private State

    private var memos: [Memo] = []
    private var lastMemoCache: (snippet: String, cachedAt: Date)?
    private let lastMemoCacheTTL: TimeInterval = 60

    // MARK: - Init

    init(weatherService: WeatherService = .shared,
         locationService: LocationService = .shared) {
        self.weatherService = weatherService
        self.locationService = locationService
    }

    // MARK: - Public API

    func update(memos: [Memo]) {
        self.memos = memos
        lastMemoCache = nil
    }

    var chips: [ContextChip] {
        var result: [ContextChip] = []

        if let weatherChip = weatherChip() { result.append(weatherChip) }
        if let locationChip = locationChip() { result.append(locationChip) }
        result.append(timeRitualChip())
        if let tailChip = lastMemoTailChip() { result.append(tailChip) }
        if let pasteChip = smartPasteChip() { result.append(pasteChip) }

        return result
    }

    // MARK: - Chip Builders

    private func weatherChip() -> ContextChip? {
        guard let cached = weatherService.cachedWeatherString else { return nil }
        let parts = cached.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1 else { return nil }
        let temp = parts[0]
        let condition = parts.count > 1 ? parts[1] : ""
        return .weather(temp: temp, condition: condition)
    }

    private func locationChip() -> ContextChip? {
        guard let loc = locationService.lastLocation else { return nil }
        let short: String
        if let name = loc.name, !name.isEmpty {
            short = String(name.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? name)
        } else if let lat = loc.lat, let lng = loc.lng {
            short = String(format: "%.2f, %.2f", lat, lng)
        } else {
            return nil
        }
        // Carry the real coordinates through; `applyChip` rebuilds a Memo.Location
        // with these instead of writing nil/nil and degrading the memo.
        return .location(short: short, lat: loc.lat, lng: loc.lng)
    }

    private func timeRitualChip() -> ContextChip {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<9:   return .timeRitual(emoji: "🌅", text: "早安")
        case 9..<12:  return .timeRitual(emoji: "☀️", text: "上午")
        case 12..<14: return .timeRitual(emoji: "🍱", text: "午间")
        case 14..<18: return .timeRitual(emoji: "🌤", text: "下午")
        case 18..<21: return .timeRitual(emoji: "🌆", text: "傍晚")
        case 21..<24: return .timeRitual(emoji: "🌙", text: "晚上")
        default:      return .timeRitual(emoji: "⭐", text: "深夜")
        }
    }

    private func lastMemoTailChip() -> ContextChip? {
        if let cache = lastMemoCache,
           Date().timeIntervalSince(cache.cachedAt) < lastMemoCacheTTL {
            return .lastMemoTail(snippet: cache.snippet)
        }

        guard let lastMemo = memos.last else { return nil }
        let body = lastMemo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let snippet = String(body.suffix(60))
        lastMemoCache = (snippet: snippet, cachedAt: Date())
        return .lastMemoTail(snippet: snippet)
    }

    private func smartPasteChip() -> ContextChip? {
        // CRITICAL: never read `UIPasteboard.general.string` here. `chips` is
        // recomputed on every SwiftUI body re-evaluation (every keystroke,
        // focus change, attachment update), and reading `.string` triggers
        // the iOS "DayPage pasted from <other app>" privacy banner *and*
        // silently loads whatever is on the clipboard (passwords, 2FA codes)
        // into the chip model without explicit user consent.
        //
        // `hasStrings` is the documented availability check that does NOT
        // count as a paste. The actual content is read on-demand inside
        // `SpotlightStripView.applyChip` only when the user taps the chip.
        guard UIPasteboard.general.hasStrings else { return nil }
        return .smartPaste
    }
}

