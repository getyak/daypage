import Foundation
import UIKit

// MARK: - ContextChip

enum ContextChip: Identifiable, Equatable {
    case weather(temp: String, condition: String)
    case location(short: String)
    case timeRitual(emoji: String, text: String)
    case lastMemoTail(snippet: String)
    case smartPaste(value: String)

    var id: String {
        switch self {
        case .weather(let temp, let condition): return "weather-\(temp)-\(condition)"
        case .location(let short): return "location-\(short)"
        case .timeRitual(let emoji, let text): return "ritual-\(emoji)-\(text)"
        case .lastMemoTail(let snippet): return "lastMemo-\(snippet.prefix(20))"
        case .smartPaste(let value): return "paste-\(value.prefix(20))"
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
        return .location(short: short)
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
        guard let string = UIPasteboard.general.string,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let value = String(string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        return .smartPaste(value: value)
    }
}

