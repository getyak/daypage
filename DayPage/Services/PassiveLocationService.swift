import Foundation
import CoreLocation

// MARK: - VisitDraft

/// A passively-detected location visit, pending user confirmation.
struct VisitDraft: Codable, Identifiable, Equatable {
    var id: UUID
    var arrivalDate: Date
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
    var placeName: String?
    var status: Status

    enum Status: String, Codable {
        case pending
        case confirmed
        case ignored
    }
}

// MARK: - PassiveLocationService

/// Uses CLLocationManager visit monitoring to detect when the user arrives at
/// significant places without draining battery.
///
/// Visits are saved to vault/drafts/visits.json as VisitDraft records.
/// The user can confirm or ignore them in TodayView.
///
/// Requires "Always" location authorization and UIBackgroundModes: location in Info.plist.
@MainActor
final class PassiveLocationService: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = PassiveLocationService()

    // MARK: - Published

    @Published var pendingDrafts: [VisitDraft] = []

    // MARK: - Private

    private let manager = CLLocationManager()
    private var isMonitoring = false

    // MARK: - Init

    private override init() {
        super.init()
        manager.delegate = self
        loadDrafts()
    }

    // MARK: - Public API

    /// Start monitoring visits if Always authorization is granted.
    func startMonitoringIfAuthorized() {
        guard manager.authorizationStatus == .authorizedAlways else { return }
        guard !isMonitoring else { return }
        manager.startMonitoringVisits()
        isMonitoring = true
    }

    /// Stop monitoring visits.
    func stopMonitoring() {
        manager.stopMonitoringVisits()
        isMonitoring = false
    }

    /// Confirm a pending draft, converting it to a location Memo in today's file.
    func confirmDraft(_ draft: VisitDraft) throws {
        let memo = Memo(
            type: .location,
            created: draft.arrivalDate,
            location: Memo.Location(
                name: draft.placeName,
                lat: draft.latitude,
                lng: draft.longitude
            )
        )
        try RawStorage.append(memo)
        updateDraftStatus(id: draft.id, status: .confirmed)
    }

    /// Ignore a pending draft.
    func ignoreDraft(_ draft: VisitDraft) {
        updateDraftStatus(id: draft.id, status: .ignored)
    }

    /// Return today's pending (unactioned) drafts.
    func todayPendingDrafts() -> [VisitDraft] {
        let calendar = Calendar.current
        return pendingDrafts.filter { draft in
            draft.status == .pending &&
            calendar.isDateInToday(draft.arrivalDate)
        }
    }

    // MARK: - Persistence

    private static var draftsURL: URL {
        let draftsDir = VaultInitializer.vaultURL.appendingPathComponent("drafts", isDirectory: true)
        return draftsDir.appendingPathComponent("visits.json")
    }

    private func loadDrafts() {
        let url = Self.draftsURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let drafts = try? JSONDecoder().decode([VisitDraft].self, from: data)
        else { return }
        pendingDrafts = drafts
    }

    private func saveDrafts() {
        let url = Self.draftsURL
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        guard let data = try? JSONEncoder().encode(pendingDrafts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func updateDraftStatus(id: UUID, status: VisitDraft.Status) {
        if let index = pendingDrafts.firstIndex(where: { $0.id == id }) {
            pendingDrafts[index].status = status
        }
        saveDrafts()
    }

    // MARK: - Geocoding

    private func geocodeAndUpdate(draftID: UUID, location: CLLocation) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, let placemark = placemarks?.first else { return }

            var parts: [String] = []
            if let name = placemark.name, !name.isEmpty {
                parts.append(name)
            }
            if let locality = placemark.locality, !parts.contains(locality) {
                parts.append(locality)
            }
            let placeName = parts.isEmpty ? placemark.country : parts.joined(separator: ", ")

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.pendingDrafts.firstIndex(where: { $0.id == draftID }) {
                    self.pendingDrafts[index].placeName = placeName
                    self.saveDrafts()
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension PassiveLocationService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways:
                self.startMonitoringIfAuthorized()
            default:
                self.stopMonitoring()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        let draft = VisitDraft(
            id: UUID(),
            arrivalDate: visit.arrivalDate == .distantPast ? Date() : visit.arrivalDate,
            departureDate: visit.departureDate == .distantFuture ? nil : visit.departureDate,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude,
            placeName: nil,
            status: .pending
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingDrafts.append(draft)
            self.saveDrafts()

            let location = CLLocation(
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude
            )
            self.geocodeAndUpdate(draftID: draft.id, location: location)
        }
    }
}
