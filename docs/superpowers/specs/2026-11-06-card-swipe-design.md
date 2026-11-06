# GET-425: Prevent accidental note navigation

The owner reports that a rightward drag over a note opens its body detail. The
accepted behavior is: a deliberate tap opens the note, a drag never opens it,
and the existing left-edge sidebar gesture remains available.

Use the shared `LocalMemoCard` for Diary, Archive and Search. Keep the native
List swipe actions, but require tapping a revealed action instead of committing
AI/share navigation with a full swipe. Preserve accessibility activation and
the existing sidebar recognizer. Do not change storage, dependencies or release
configuration.

Prefer a tap-specific primitive button interaction over a simultaneous drag
guard: it avoids a stale cancellation flag or a new drag recognizer competing
with List scrolling and the sidebar. Confirm the approach in actual Simulator
journeys before keeping it. An enlarged sidebar zone is deferred because it
does not address body-button activation and changes unrelated touch ownership.

Acceptance covers short horizontal/diagonal/out-and-back drags, full swipes,
ordinary taps, vertical scrolling, sidebar opening/closing and the shared
Archive/Search card. Simulator evidence does not establish physical-device
acceptance. No TestFlight publication is requested.
