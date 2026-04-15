import SwiftUI

/// Graph Tab — MVP placeholder (disabled / coming soon)
struct GraphView: View {
    var body: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("GRAPH")
                    .displayLGStyle()
                    .foregroundColor(DSColor.outlineVariant)
                Text("敬请期待")
                    .bodyMDStyle()
                    .foregroundColor(DSColor.onSurfaceVariant)
            }
        }
    }
}
