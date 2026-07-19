import Testing
@testable import DayPage

// Regression suite for the MemoDetailView photo-detail crash (2026-07-19).
//
// Bug: a memo card containing a photo whose EXIF `ExposureTime` was exactly 0
// crashed the app on opening MemoDetailView. The two shutter-label sites used
// `Int(1.0 / shutter)` with no guard; `1.0 / 0.0` is `+Inf`, and `Int(+Inf)`
// is a Swift fatal error ("Double value cannot be converted to Int because it
// is either infinite or NaN"), taking the whole process down.
//
// The fix routes both sites through `MemoExifFormat.shutterLabel(exposureTime:)`,
// which guards `> 0` and `isFinite` before the `Int(...)` conversion. These
// tests pin that contract: every input that used to trap now yields `nil`
// (the field is simply omitted), and valid exposures still format correctly.
//
// Note: these inputs (0 / negative / infinity / NaN) are exactly the values
// that made the OLD inline `Int(1.0 / shutter)` trap or produce garbage. The
// suite exercising them without crashing IS the proof the fix holds — a build
// with the old code would have needed the same guard to even run this.
@Suite("MemoExifFormat.shutterLabel")
struct MemoExifShutterTests {

    // MARK: - Crash inputs (the regression) — must be nil, never trap

    @Test func zeroExposureReturnsNil() {
        // The exact crash trigger: 1.0 / 0.0 = +Inf → Int(+Inf) fatal.
        #expect(MemoExifFormat.shutterLabel(exposureTime: 0) == nil)
    }

    @Test func negativeExposureReturnsNil() {
        #expect(MemoExifFormat.shutterLabel(exposureTime: -0.5) == nil)
    }

    @Test func infiniteExposureReturnsNil() {
        #expect(MemoExifFormat.shutterLabel(exposureTime: .infinity) == nil)
    }

    @Test func nanExposureReturnsNil() {
        #expect(MemoExifFormat.shutterLabel(exposureTime: .nan) == nil)
    }

    // MARK: - Valid exposures — format correctly

    @Test func fastShutterFormats() {
        // 1/125s exposure → "1/125s".
        #expect(MemoExifFormat.shutterLabel(exposureTime: 1.0 / 125.0) == "1/125s")
    }

    @Test func typicalHandheldShutterFormats() {
        // 1/60s.
        #expect(MemoExifFormat.shutterLabel(exposureTime: 1.0 / 60.0) == "1/60s")
    }

    @Test func slowSubSecondShutterFormatsAsFraction() {
        // 0.5s → reciprocal 2 → "1/2s". Rounding (not truncation) keeps
        // near-integer reciprocals from drifting a frame.
        #expect(MemoExifFormat.shutterLabel(exposureTime: 0.5) == "1/2s")
    }

    @Test func oneSecondAndLongerRenderAsWholeSeconds() {
        // The old inline code turned a 2s exposure into "1/0s" (Int(0.5)=0);
        // ≥1s exposures now read as whole seconds. Neither traps.
        #expect(MemoExifFormat.shutterLabel(exposureTime: 1.0) == "1s")
        #expect(MemoExifFormat.shutterLabel(exposureTime: 2.0) == "2s")
        #expect(MemoExifFormat.shutterLabel(exposureTime: 30.0) == "30s")
    }

    // MARK: - Focal length (same Int(Double) trap class as shutter)

    @Test func focalLengthFormats() {
        #expect(MemoExifFormat.focalLengthLabel(26.0) == "26mm")
        #expect(MemoExifFormat.focalLengthLabel(50.4) == "50mm")  // rounds
    }

    @Test func focalLengthCrashInputsReturnNil() {
        // Int(.infinity) / Int(.nan) is a fatal error — the same trap the
        // shutter path had. These must be guarded to nil, never trap.
        #expect(MemoExifFormat.focalLengthLabel(0) == nil)
        #expect(MemoExifFormat.focalLengthLabel(-5) == nil)
        #expect(MemoExifFormat.focalLengthLabel(.infinity) == nil)
        #expect(MemoExifFormat.focalLengthLabel(.nan) == nil)
    }

    // MARK: - Aperture

    @Test func apertureFormats() {
        #expect(MemoExifFormat.apertureLabel(2.8) == "f/2.8")
        #expect(MemoExifFormat.apertureLabel(1.4) == "f/1.4")
    }

    @Test func apertureCrashInputsReturnNil() {
        // Doesn't trap, but "f/inf" / "f/nan" is nonsense metadata.
        #expect(MemoExifFormat.apertureLabel(0) == nil)
        #expect(MemoExifFormat.apertureLabel(.infinity) == nil)
        #expect(MemoExifFormat.apertureLabel(.nan) == nil)
    }
}
