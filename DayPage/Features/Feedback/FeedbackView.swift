import SwiftUI

// MARK: - FeedbackView

struct FeedbackView: View {

    @StateObject private var vm = FeedbackViewModel()
    @State private var showConfig = false

    var body: some View {
        ZStack {
            DSColor.backgroundWarm.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    Divider()
                        .background(DSColor.borderSubtle)
                        .padding(.bottom, 20)

                    if case .submitted(let url) = vm.status {
                        successView(url: url)
                    } else {
                        feedbackInputSection
                        if vm.isReady || vm.isSubmitting || vm.isIdle && !vm.aiTitle.isEmpty {
                            previewSection
                        }
                        configSection
                    }

                    if let err = vm.errorMessage {
                        errorBanner(message: err)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Feedback")
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .foregroundColor(DSColor.onBackgroundPrimary)
            Text("Write feedback → AI summarizes → create GitHub issue")
                .font(.custom("Inter-Regular", size: 13))
                .foregroundColor(DSColor.onBackgroundSubtle)
        }
        .padding(.top, 64)
        .padding(.bottom, 16)
    }

    // MARK: - Feedback Input

    private var feedbackInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Your Feedback")

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(DSColor.surfaceWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DSColor.borderDefault, lineWidth: 1)
                    )

                if vm.rawFeedback.isEmpty {
                    Text("Describe a bug, feature request, or improvement…")
                        .font(.custom("Inter-Regular", size: 15))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                TextEditor(text: $vm.rawFeedback)
                    .font(.custom("Inter-Regular", size: 15))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(10)
                    .frame(minHeight: 140)
            }
            .frame(minHeight: 140)

            HStack {
                Spacer()
                summarizeButton
            }
        }
        .padding(.bottom, 24)
    }

    private var summarizeButton: some View {
        Button {
            Task { await vm.summarizeWithAI() }
        } label: {
            HStack(spacing: 6) {
                if vm.isSummarizing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(DSColor.onPrimary)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                }
                Text(vm.isSummarizing ? "Summarizing…" : "AI Summarize")
                    .font(.custom("Inter-SemiBold", size: 14))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(vm.isSummarizing ? DSColor.accentAmber.opacity(0.7) : DSColor.accentAmber)
            .cornerRadius(8)
        }
        .disabled(vm.isSummarizing || vm.isSubmitting)
    }

    // MARK: - Preview / Editable Card

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Issue Preview")

            VStack(alignment: .leading, spacing: 14) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title")
                        .font(.custom("Inter-Medium", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                    TextField("Issue title", text: $vm.aiTitle)
                        .font(.custom("Inter-SemiBold", size: 15))
                        .foregroundColor(DSColor.onBackgroundPrimary)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(DSColor.surfaceSunken)
                        .cornerRadius(8)
                }

                // Labels
                if !vm.aiLabels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Labels")
                            .font(.custom("Inter-Medium", size: 12))
                            .foregroundColor(DSColor.onBackgroundSubtle)
                        HStack(spacing: 6) {
                            ForEach(vm.aiLabels, id: \.self) { label in
                                labelChip(label)
                            }
                        }
                    }
                }

                // Body
                VStack(alignment: .leading, spacing: 4) {
                    Text("Body")
                        .font(.custom("Inter-Medium", size: 12))
                        .foregroundColor(DSColor.onBackgroundSubtle)

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DSColor.surfaceSunken)

                        TextEditor(text: $vm.aiBody)
                            .font(.custom("JetBrainsMono-Regular", size: 12))
                            .foregroundColor(DSColor.onBackgroundPrimary)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .padding(8)
                            .frame(minHeight: 180)
                    }
                    .frame(minHeight: 180)
                }

                // Submit button
                submitButton
            }
            .padding(16)
            .background(DSColor.surfaceWhite)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DSColor.accentBorder, lineWidth: 1)
            )
            .cornerRadius(12)
            .surfaceElevatedShadow()
        }
        .padding(.bottom, 24)
    }

    private func labelChip(_ label: String) -> some View {
        Text(label)
            .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
            .foregroundColor(DSColor.accentAmber)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DSColor.accentSoft)
            .overlay(
                Capsule().stroke(DSColor.accentBorder, lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private var submitButton: some View {
        Button {
            Task { await vm.submitToGitHub() }
        } label: {
            HStack(spacing: 8) {
                if vm.isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                }
                Text(vm.isSubmitting ? "Creating Issue…" : "Create GitHub Issue")
                    .font(.custom("Inter-SemiBold", size: 15))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(vm.isSubmitting ? DSColor.accentAmber.opacity(0.7) : DSColor.accentAmber)
            .cornerRadius(10)
        }
        .disabled(vm.isSubmitting || vm.isSummarizing)
    }

    // MARK: - Config Section

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showConfig.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                    Text("GitHub Configuration")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(DSColor.onBackgroundMuted)
                    Spacer()
                    Image(systemName: showConfig ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
            .buttonStyle(.plain)

            if showConfig {
                configFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 16)
    }

    private var configFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            configField(label: "Repo Owner", placeholder: "e.g. cubxxw", binding: repoOwnerBinding)
            configField(label: "Repo Name", placeholder: "e.g. daypage", binding: repoNameBinding)
            tokenField
        }
        .padding(14)
        .background(DSColor.surfaceSunken)
        .cornerRadius(10)
    }

    private func configField(label: String, placeholder: String, binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.onBackgroundSubtle)
            TextField(placeholder, text: binding)
                .font(.custom("Inter-Regular", size: 14))
                .foregroundColor(DSColor.onBackgroundPrimary)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(DSColor.surfaceWhite)
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(DSColor.borderDefault, lineWidth: 1)
                )
        }
    }

    private var tokenField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GitHub Token")
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.onBackgroundSubtle)
            SecureField("ghp_…", text: tokenBinding)
                .font(.custom("JetBrainsMono-Regular", size: 13))
                .foregroundColor(DSColor.onBackgroundPrimary)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(10)
                .background(DSColor.surfaceWhite)
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(DSColor.borderDefault, lineWidth: 1)
                )
            Text("Stored in Keychain. Needs issues:write scope.")
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(DSColor.onBackgroundSubtle)
        }
    }

    // MARK: - Success View

    private func successView(url: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(DSColor.successGreen)

            Text("Issue Created!")
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .foregroundColor(DSColor.onBackgroundPrimary)

            Text(url)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundColor(DSColor.onBackgroundMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let link = URL(string: url) {
                Link(destination: link) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                        Text("Open in GitHub")
                            .font(.custom("Inter-SemiBold", size: 15))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(DSColor.accentAmber)
                    .cornerRadius(10)
                }
            }

            Button("Submit Another") {
                vm.reset()
            }
            .font(.custom("Inter-Regular", size: 14))
            .foregroundColor(DSColor.onBackgroundMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(DSColor.errorRed)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.custom("Inter-Regular", size: 13))
                    .foregroundColor(DSColor.errorRed)
                Button("Dismiss") {
                    vm.status = .idle
                }
                .font(.custom("Inter-Medium", size: 12))
                .foregroundColor(DSColor.onBackgroundMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(DSColor.errorSoft)
        .cornerRadius(10)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("Inter-SemiBold", size: 12))
            .foregroundColor(DSColor.onBackgroundSubtle)
            .kerning(0.5)
            .textCase(.uppercase)
    }

    // Bindings that write-through to UserDefaults via vm
    private var repoOwnerBinding: Binding<String> {
        Binding(
            get: { vm.repoOwner },
            set: { vm.repoOwner = $0 }
        )
    }

    private var repoNameBinding: Binding<String> {
        Binding(
            get: { vm.repoName },
            set: { vm.repoName = $0 }
        )
    }

    private var tokenBinding: Binding<String> {
        Binding(
            get: { vm.githubToken },
            set: { vm.githubToken = $0 }
        )
    }
}
