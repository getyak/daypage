import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService

    @State private var showSettings = false
    @State private var showAccountSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
            Divider()
                .background(DSColor.borderSubtle)
                .padding(.bottom, 8)

            navSection

            Spacer()

            Divider()
                .background(DSColor.borderSubtle)

            bottomSection
        }
        .frame(maxHeight: .infinity)
        .background(DSColor.backgroundWarm)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DAYPAGE")
                .font(.custom("SpaceGrotesk-Bold", size: 18))
                .foregroundColor(DSColor.onBackgroundPrimary)
                .kerning(2)
            Text("your daily log")
                .font(.custom("Inter-Regular", size: 12))
                .foregroundColor(DSColor.onBackgroundSubtle)
        }
        .padding(.horizontal, 24)
        .padding(.top, 64)
        .padding(.bottom, 24)
    }

    // MARK: - Nav Items

    private var navSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            navItem(tab: .today, icon: "square.and.pencil", label: "Today")
            navItem(tab: .archive, icon: "archivebox", label: "Archive")
            navItem(tab: .graph, icon: "point.3.connected.trianglepath.dotted", label: "Graph", disabled: true)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func navItem(tab: AppTab, icon: String, label: String, disabled: Bool = false) -> some View {
        let isActive = nav.selectedTab == tab

        Button {
            guard !disabled else { return }
            nav.navigate(to: tab)
        } label: {
            HStack(spacing: 12) {
                // Left accent bar
                Rectangle()
                    .fill(isActive ? DSColor.accentAmber : Color.clear)
                    .frame(width: 2, height: 20)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(
                        disabled ? DSColor.onBackgroundSubtle
                        : isActive ? DSColor.accentAmber
                        : DSColor.onBackgroundMuted
                    )

                Text(label)
                    .font(.custom(isActive ? "Inter-SemiBold" : "Inter-Regular", size: 15))
                    .foregroundColor(
                        disabled ? DSColor.onBackgroundSubtle
                        : isActive ? DSColor.onBackgroundPrimary
                        : DSColor.onBackgroundMuted
                    )

                if disabled {
                    Spacer()
                    Text("Post-MVP")
                        .font(.custom("JetBrainsMono-Regular", fixedSize: 9))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DSColor.borderSubtle)
                }
            }
            .padding(.leading, 0)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DSColor.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Section

    private var bottomSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Settings
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 2, height: 20)
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 20)
                        .foregroundColor(DSColor.onBackgroundMuted)
                    Text("Settings")
                        .font(.custom("Inter-Regular", size: 15))
                        .foregroundColor(DSColor.onBackgroundMuted)
                }
                .padding(.trailing, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Account (when logged in)
            if authService.session != nil {
                accountRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.bottom, 24)
    }

    private var accountRow: some View {
        let email = authService.session?.user.email ?? ""
        let initial = email.first.map { String($0).uppercased() } ?? "?"

        return Button {
            showAccountSheet = true
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 2, height: 20)
                ZStack {
                    Circle()
                        .fill(DSColor.accentSoft)
                        .frame(width: 26, height: 26)
                    Text(initial)
                        .font(.custom("Inter-Medium", size: 12))
                        .foregroundColor(DSColor.accentAmber)
                }
                .frame(width: 20)
                Text(email)
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.onBackgroundMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
