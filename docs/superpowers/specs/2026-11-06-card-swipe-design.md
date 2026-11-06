# GET-425: Prevent accidental note navigation

The owner reports that a rightward drag over a note opens its body detail. The
accepted behavior is: a deliberate tap opens the note, a drag never opens it,
and the existing left-edge sidebar gesture remains available.

Use the shared `LocalMemoCard` for Diary, Archive and Search. Keep the native
List swipe actions, but require tapping a revealed action instead of committing
AI/share navigation with a full swipe. Preserve accessibility activation and
the existing sidebar recognizer. Do not change storage, dependencies or release
configuration.

Use a primitive button style with a transparent UIKit tap surface over its
label. The tap recognizer fails as soon as any sampled movement reaches 8pt;
it does not register a pan or take native List gestures away. A held touch
(0.4s or longer) cannot fall through to navigation, leaving long presses to the
ancestor context menu. Per-touch origin/time reset with UIKit's lifecycle;
there is no cooldown timer or suppression state carried to the next touch.

A standard TapGesture alone still accepted the 18pt Archive drag. A SwiftUI
exclusive drag-before-tap fixed that drag but prevented native List row swipes
despite simultaneous composition. Those actual regressions justify the UIKit
boundary; the legacy client's HorizontalPanGesture also documents the same
SwiftUI pan arbitration limitation. Do not import that client's pan behavior.
An enlarged sidebar zone is deferred because it changes unrelated ownership.
The 8pt/0.4s bounds are implementation choices. Verify 18pt drags, 3pt natural
tap movement and body long-press menu behavior in Simulator.

Acceptance covers short horizontal/diagonal/out-and-back drags, full swipes,
ordinary taps, vertical scrolling, sidebar opening/closing and the shared
Archive/Search card. Simulator evidence does not establish physical-device
acceptance. No TestFlight publication is requested.
