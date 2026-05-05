import SwiftUI

// MARK: - SidebarView

struct SidebarView: View {

    @EnvironmentObject private var nav: AppNavigationModel
    @EnvironmentObject private var authService: AuthService

    @State private var showSettings = false
    @State private var showAccountSheet = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            DSColor.bgWarm.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                brandHeader

                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)
                    .padding(.bottom, 8)

                navSection

                Spacer()

                Rectangle()
                    .fill(DSColor.inkFaint)
                    .frame(height: 0.5)

                bottomSection
            }
            .frame(maxHeight: .infinity)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAccountSheet) {
            AccountSheet()
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DayPage")
                .font(DSType.serifDisplay32)
                .foregroundColor(DSColor.inkPrimary)
            Text("your daily log")
                .font(DSType.mono10)
                .foregroundColor(DSColor.inkSubtle)
                .textCase(.uppercase)
                .tracking(1.0)
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
            navItem(tab: .feedback, icon: "bubble.left.and.exclamationmark.bubble.right", label: "Feedback")
            navItem(tab: .graph, icon: "point.3.connected.trianglepath.dotted", label: "Graph", disabled: true)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func navItem(tab: AppTab, icon: String, label: String, disabled: Bool = false) -> some View {
        let isActive = nav.selectedTab == tab

        Button {
            guard !disabled else { return }
            if tab == .feedback {
                nav.openFeedbackPanel()
            } else {
                nav.navigate(to: tab)
            }
        } label: {
            HStack(spacing: 12) {
                // Left amber accent strip
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? DSColor.amberAccent : Color.clear)
                    .frame(width: 2, height: 20)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 20)
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.amberAccent
                        : DSColor.inkMuted
                    )

                Text(label)
                    .font(isActive ? DSType.titleSM : DSType.bodyMD)
                    .foregroundColor(
                        disabled ? DSColor.inkSubtle
                        : isActive ? DSColor.inkPrimary
                        : DSColor.inkMuted
                    )

                if disabled {
                    Spacer()
                    Text("Post-MVP")
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkSubtle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DSColor.amberSoft, in: Capsule())
                }
            }
            .padding(.leading, 0)
            .padding(.trailing, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? DSColor.amberSoft : Color.clear)
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
                    Color.clear.frame(width: 2, height: 20)
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 20)
                        .foregroundColor(DSColor.inkMuted)
                    Text("Settings")
                        .font(DSType.bodyMD)
                        .foregroundColor(DSColor.inkMuted)
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
                Color.clear.frame(width: 2, height: 20)
                ZStack {
                    Circle()
                        .fill(DSColor.amberSoft)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(DSColor.amberRim, lineWidth: 0.5))
                    Text(initial)
                        .font(DSType.labelSM)
                        .foregroundColor(DSColor.amberDeep)
                }
                .frame(width: 20)
                Text(email)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
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
