import SwiftUI

// MARK: - FeedbackView

struct FeedbackView: View {

    @StateObject private var vm = FeedbackViewModel()

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
                    }

                    if let err = vm.errorMessage {
                        errorBanner(message: err)
                    }

                    if !vm.submittedIssues.isEmpty {
                        submittedIssuesSection
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
        }
        .alert("Microphone Permission Required", isPresented: $vm.showMicPermissionAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Please enable microphone and speech recognition access in Settings to use voice input.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Feedback")
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .foregroundColor(DSColor.onBackgroundPrimary)
            Text("Describe → AI summarizes → direct to GitHub")
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
                micButton
                Spacer()
                summarizeButton
            }
        }
        .padding(.bottom, 24)
    }

    private var micButton: some View {
        Button {
            vm.transcribeVoice()
        } label: {
            ZStack {
                Circle()
                    .fill(vm.isRecording ? Color.red.opacity(0.15) : DSColor.surfaceWhite)
                    .frame(width: 40, height: 40)
                    .overlay(
                        Circle().stroke(
                            vm.isRecording ? Color.red : DSColor.borderDefault,
                            lineWidth: 1
                        )
                    )

                Image(systemName: vm.isRecording ? "waveform" : "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(vm.isRecording ? Color.red : DSColor.onBackgroundMuted)
                    .opacity(vm.isRecording ? 1.0 : 0.7)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: vm.isRecording)
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if vm.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.isRecording)
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
                Text(vm.isSubmitting ? "Submitting…" : "Submit to GitHub")
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

    // MARK: - Submitted Issues

    private var submittedIssuesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Submitted Issues")

            VStack(alignment: .leading, spacing: 0) {
                ForEach(vm.submittedIssues) { issue in
                    submittedIssueRow(issue)
                    if issue.id != vm.submittedIssues.last?.id {
                        Divider()
                            .background(DSColor.borderSubtle)
                            .padding(.leading, 14)
                    }
                }
            }
            .background(DSColor.surfaceWhite)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DSColor.borderDefault, lineWidth: 1)
            )
        }
        .padding(.bottom, 24)
    }

    private func submittedIssueRow(_ issue: SubmittedIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.custom("Inter-Medium", size: 13))
                    .foregroundColor(DSColor.onBackgroundPrimary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("#\(issue.number)")
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundColor(DSColor.accentAmber)
                    Text("·")
                        .foregroundColor(DSColor.onBackgroundSubtle)
                    Text(issue.date, style: .date)
                        .font(.custom("Inter-Regular", size: 11))
                        .foregroundColor(DSColor.onBackgroundSubtle)
                }
            }
            Spacer()
            if let link = URL(string: issue.url) {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                        .foregroundColor(DSColor.onBackgroundMuted)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
}
