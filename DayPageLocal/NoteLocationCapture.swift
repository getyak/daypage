import Combine
import CoreLocation
import DayPageCore
import Foundation

enum NoteLocationError: LocalizedError, Sendable {
  case denied, unavailable

  var errorDescription: String? {
    switch self {
    case .denied:
      return String(localized: "Location access is off. You can enable it in Settings or save without a location.")
    case .unavailable:
      return String(localized: "Couldn't find your location. Try again or save without a location.")
    }
  }
}

/// No manager, permission prompt or location work exists until explicit request().
@MainActor
final class NoteLocationCapture: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
  @Published private(set) var isRequesting = false
  private var manager: CLLocationManager?
  private var completion: ((Result<Memo.Location, NoteLocationError>) -> Void)?
  private var timeout: Task<Void, Never>?
  private var requestID = UUID()
  private var requestedFix = false

  func request(completion: @escaping (Result<Memo.Location, NoteLocationError>) -> Void) {
    cancel()
    self.completion = completion
    isRequesting = true
    let id = requestID
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if Bundle.main.bundleIdentifier == "com.daypage.app.localqa",
         args.contains("-qaNotebookSession"), args.contains("-qaLocationFixture") {
        // Only the isolated QA binary can use synthetic coordinates. This does
        // not establish real permission/device-location evidence.
        timeout = Task { [weak self] in
          // Keep the request pending long enough to inspect and tap Cancel.
          // The UI test then observes beyond this entire synthetic deadline.
          try? await Task.sleep(for: .milliseconds(args.contains("-qaLocationDelay") ? 10_000 : 200))
          guard !Task.isCancelled, let self, self.requestID == id else { return }
          self.finish(.success(Memo.Location(name: "Synthetic place", lat: 31.25, lng: 121.5)))
        }
        return
      }
    #endif
    // Core Location delivers delegates on the manager's initialization run loop.
    // Construct it on MainActor; the preconcurrency conformance checks that
    // isolation at runtime for this Objective-C delegate protocol.
    let manager = CLLocationManager()
    self.manager = manager
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: requestFix(manager)
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .denied, .restricted: finish(.failure(.denied))
    @unknown default: finish(.failure(.unavailable))
    }
  }

  func cancel() {
    requestID = UUID()
    timeout?.cancel()
    timeout = nil
    manager?.stopUpdatingLocation()
    manager?.delegate = nil
    manager = nil
    requestedFix = false
    completion = nil
    isRequesting = false
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    guard self.manager === manager else { return }
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: requestFix(manager)
    case .denied, .restricted: finish(.failure(.denied))
    case .notDetermined: break
    @unknown default: finish(.failure(.unavailable))
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard self.manager === manager else { return }
    guard let fix = locations.last(where: {
      $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) <= 120
    }) else {
      finish(.failure(.unavailable))
      return
    }
    let location = Memo.Location(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude)
    guard location.hasValidCoordinates else { finish(.failure(.unavailable)); return }
    finish(.success(location))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard self.manager === manager else { return }
    finish(.failure((error as? CLError)?.code == .denied ? .denied : .unavailable))
  }

  private func requestFix(_ manager: CLLocationManager) {
    guard self.manager === manager, !requestedFix else { return }
    requestedFix = true
    let id = requestID
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(20))
      guard !Task.isCancelled, let self, self.requestID == id else { return }
      self.finish(.failure(.unavailable))
    }
    manager.requestLocation()
  }

  private func finish(_ result: Result<Memo.Location, NoteLocationError>) {
    let callback = completion
    cancel()
    callback?(result)
  }
}
