import SwiftUI

struct ArchiveView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("ARCHIVE")
                            .headlineMDStyle()
                            .foregroundColor(DSColor.onSurface)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(DSColor.outline)

                    // Placeholder content
                    Spacer()
                    Text("ARCHIVE")
                        .displayLGStyle()
                        .foregroundColor(DSColor.outlineVariant)
                    Spacer()
                }
            }
            .navigationBarHidden(true)
        }
    }
}
