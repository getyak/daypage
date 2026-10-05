import Foundation
import Testing
import UIKit
import Vision
@testable import DayPage

extension DayPageSerialSwiftTests {
    @Suite("ShareCardLocationIntegrity")
    @MainActor
    struct ShareCardLocationIntegrityTests {
        @Test func filmOmitsUnprovidedLocation() throws { try assertNoInventedLocation(style: .film) }
        @Test func journalOmitsUnprovidedLocation() throws { try assertNoInventedLocation(style: .journal) }
        @Test func postcardOmitsUnprovidedLocation() throws { try assertNoInventedLocation(style: .postcard) }
        @Test func filmPreservesProvidedLocation() throws { try assertProvidedLocation(style: .film) }
        @Test func journalPreservesProvidedLocation() throws { try assertProvidedLocation(style: .journal) }
        @Test func postcardPreservesProvidedLocation() throws { try assertProvidedLocation(style: .postcard) }

        private func assertNoInventedLocation(style: PosterStyle) throws {
            for location in [nil, ""] as [String?] {
                for payload in payloads(location: location) {
                    let text = try recognize(PosterDispatcher.render(payload: payload, style: style, colorScheme: .light))
                    // Confirm that recognition read the actual user content before
                    // using absence as evidence. This exercises the rendered pixels,
                    // including the postcard stamp, rather than a metadata helper.
                    #expect(text.contains("METADATA"), "OCR control text missing: \(text)")
                    #expect(!text.contains("VIENTIANE"), "Unprovided city was rendered: \(text)")
                    #expect(!text.contains("LAOS"), "Unprovided country was rendered: \(text)")
                    #expect(!text.contains("18.04") && !text.contains("102.64"), "Unprovided coordinates were rendered: \(text)")
                }
            }
        }

        private func assertProvidedLocation(style: PosterStyle) throws {
            for payload in payloads(location: "BOSTON") {
                let text = try recognize(PosterDispatcher.render(payload: payload, style: style, colorScheme: .light))
                #expect(text.contains("METADATA"), "OCR control text missing: \(text)")
                #expect(text.contains("BOSTON"), "Supplied location was lost: \(text)")
                #expect(!text.contains("LAOS"), "A country was invented for a supplied place: \(text)")
                #expect(!text.contains("18.04") && !text.contains("102.64"), "Example coordinates replaced supplied location: \(text)")
            }
        }

        private func payloads(location: String?) -> [SharePayload] {
            let date = Date(timeIntervalSince1970: 1_791_031_068)
            let body = "CARD METADATA CHECK"
            let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                UIColor.lightGray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            return [
                .memo(MemoSnapshot(id: UUID(), body: body, createdAt: date, locationName: location,
                                   weather: nil, coverImage: nil, voiceDurationSeconds: nil, memoType: "TEXT")),
                .daily(DailySnapshot(dateString: "2026-10-03", weekday: "SATURDAY", summary: body,
                                    locationPrimary: location ?? "", memoCount: 1, coverImage: nil,
                                    highlights: [], sections: [], photoCount: 0, voiceCount: 0, locationEntries: [])),
                .photo(PhotoSnapshot(id: UUID(), image: image, caption: body,
                                     location: location, time: "20:37", exif: nil))
            ]
        }

        private func recognize(_ image: UIImage) throws -> String {
            let cgImage = try #require(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.005
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            let observations = try #require(request.results)
            return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
        }
    }
}
