import CoreHaptics
import UIKit

/// Signature CoreHaptics moments for DayPage.
///
/// Unlike `HapticFeedback` (thin wrappers over the stock UIKit generators),
/// this type authors custom `CHHapticPattern`s that give key product moments
/// a recognizable, ownable texture. First signature: compilation success —
/// "ink settling onto paper" (墨水落纸): a rising run of soft transient taps
/// (the pen touching down) followed by a quiet continuous rumble that decays
/// to nothing (the ink being absorbed by the page).
///
/// Design contract:
/// - Never throws out of the public API.
/// - On unsupported hardware or ANY engine/pattern failure, silently falls
///   back to `HapticFeedback.success()` so the moment is never mute.
/// - The engine is created lazily and stopped when playback finishes
///   (`.stopEngine`), so it holds no haptic-server resources at rest.
@MainActor
enum SignatureHaptics {

    // MARK: - State

    /// Lazily-created shared engine. Nil until first use, and nilled out on
    /// server reset so the next call rebuilds from a clean slate.
    private static var engine: CHHapticEngine?

    private static var supportsHaptics: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Public API

    /// 墨水落纸 — the compilation-success signature.
    ///
    /// Pattern (total ≈ 0.51s):
    /// - 4 transients rising in intensity 0.30 → 0.45 → 0.58 → 0.70,
    ///   sharpness easing 0.45 → 0.38, spaced 70ms apart (t = 0, 0.07,
    ///   0.14, 0.21).
    /// - 1 continuous event at t = 0.26 for 0.25s, intensity 0.35,
    ///   sharpness 0.20, with an intensity-control curve decaying
    ///   1.0 → 0.0 across its duration (the "settling").
    ///
    /// Recognizably distinct from the stock `.success` notification
    /// (two fixed medium transients).
    static func compileSuccess() {
        guard supportsHaptics else {
            HapticFeedback.success()
            return
        }
        do {
            let engine = try sharedEngine()
            try engine.start()
            let player = try engine.makePlayer(with: inkSettlingPattern())
            try player.start(atTime: CHHapticTimeImmediate)
            // Release the Taptic Engine as soon as the pattern completes —
            // per-call player creation is fine at this event frequency.
            engine.notifyWhenPlayersFinished { _ in .stopEngine }
        } catch {
            HapticFeedback.success()
        }
    }

    // MARK: - Engine Lifecycle

    private static func sharedEngine() throws -> CHHapticEngine {
        if let existing = engine {
            return existing
        }
        let newEngine = try CHHapticEngine()
        newEngine.playsHapticsOnly = true
        // The haptic server can reset (audio interruption, backgrounding).
        // Handlers run off the main actor, so hop back before touching our
        // state; dropping the engine forces a clean rebuild on next call.
        newEngine.resetHandler = {
            Task { @MainActor in
                SignatureHaptics.engine = nil
            }
        }
        newEngine.stoppedHandler = { _ in
            // Expected after `.stopEngine`; the next compileSuccess()
            // restarts the retained engine with `start()`.
        }
        engine = newEngine
        return newEngine
    }

    // MARK: - Pattern

    /// Builds the "ink settling onto paper" pattern.
    private static func inkSettlingPattern() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = []

        // The pen touching down: rising taps, softening sharpness.
        let taps: [(time: TimeInterval, intensity: Float, sharpness: Float)] = [
            (0.00, 0.30, 0.45),
            (0.07, 0.45, 0.42),
            (0.14, 0.58, 0.40),
            (0.21, 0.70, 0.38),
        ]
        for tap in taps {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: tap.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: tap.sharpness),
                ],
                relativeTime: tap.time
            ))
        }

        // The ink being absorbed: soft sustained rumble that decays away.
        let settleStart: TimeInterval = 0.26
        let settleDuration: TimeInterval = 0.25
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.20),
            ],
            relativeTime: settleStart,
            duration: settleDuration
        ))

        // Multiplicative intensity curve: full strength until the continuous
        // event begins, then a linear fade to silence. The curve holds its
        // first control-point value before it, so transients are unaffected.
        let decay = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: settleStart, value: 1.0),
                CHHapticParameterCurve.ControlPoint(relativeTime: settleStart + settleDuration, value: 0.0),
            ],
            relativeTime: 0
        )

        return try CHHapticPattern(events: events, parameterCurves: [decay])
    }
}
