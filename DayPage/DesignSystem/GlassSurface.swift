import SwiftUI

// MARK: - Ambient Background
//
// Default: pure cream base (DSColor.bgWarm / #FAF7F2) — clean paper feel.
// Amber blobs are available for debug inspection via UserDefaults key
// "debug.ambientBlobs" (default false).

struct AmbientBackground: View {
    @AppStorage("debug.ambientBlobs") private var showBlobs: Bool = false

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            if showBlobs {
                // Top-left peach highlight
                Circle()
                    .fill(Color(hex: "E8974D").opacity(0.55))
                    .frame(width: 360, height: 360)
                    .blur(radius: 80)
                    .offset(x: -60, y: -100)

                // Top-right warm yellow
                Circle()
                    .fill(Color(hex: "FFCE8C").opacity(0.55))
                    .frame(width: 320, height: 320)
                    .blur(radius: 80)
                    .offset(x: 140, y: -50)

                // Center-left deep amber
                Circle()
                    .fill(Color(hex: "A8541B").opacity(0.32))
                    .frame(width: 420, height: 420)
                    .blur(radius: 80)
                    .offset(x: -20, y: 200)

                // Bottom-right warm rust
                Circle()
                    .fill(Color(hex: "D98D54").opacity(0.40))
                    .frame(width: 300, height: 300)
                    .blur(radius: 80)
                    .offset(x: 100, y: 300)
            }
        }
        .allowsHitTesting(false)
    }
}
