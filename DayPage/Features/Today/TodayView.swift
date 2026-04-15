import SwiftUI

struct TodayView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text("TODAY")
                            .headlineMDStyle()
                            .foregroundColor(DSColor.onSurface)
                        Spacer()
                        Text(Date(), format: .dateTime.month().day())
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(DSColor.outline)

                    // Timeline placeholder
                    ScrollView {
                        VStack(spacing: 16) {
                            Spacer(minLength: 24)
                            Text("今日还未编译")
                                .bodyMDStyle()
                                .foregroundColor(DSColor.onSurfaceVariant)
                            Spacer(minLength: 24)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                    }
                    .frame(maxHeight: .infinity)

                    Divider()
                        .background(DSColor.outline)

                    // Input bar placeholder
                    HStack(spacing: 12) {
                        Text("记录想法…")
                            .bodyMDStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(DSColor.surfaceContainerLow)
                }
            }
            .navigationBarHidden(true)
        }
    }
}
