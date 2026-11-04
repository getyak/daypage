import DayPageCore
import SwiftUI

extension NoteActionKind {
  var title: String {
    switch self {
    case .create: return String(localized: "Create note")
    case .append: return String(localized: "Append to note")
    case .patch: return String(localized: "Edit note")
    case .setTags: return String(localized: "Replace note tags")
    case .setPin: return String(localized: "Change pin")
    case .link: return String(localized: "Connect notes")
    case .unlink: return String(localized: "Remove connection")
    }
  }
  var toolName: String {
    switch self {
    case .create: return "notes_create"
    case .append: return "notes_append"
    case .patch: return "notes_propose_patch"
    case .setTags: return "notes_set_tags"
    case .setPin: return "notes_set_pin"
    case .link: return "relations_link"
    case .unlink: return "relations_unlink"
    }
  }
}

extension NoteRelationType {
  var title: String {
    switch self {
    case .related: return String(localized: "Related topic")
    case .supplements: return String(localized: "Adds detail")
    case .contradicts: return String(localized: "Different viewpoints")
    case .evolves: return String(localized: "Develops an earlier idea")
    case .duplicate: return String(localized: "Overlapping content")
    case .derivedFrom: return String(localized: "Based on this note")
    }
  }
}

struct NoteActionCard: View {
  @EnvironmentObject private var notebook: NotebookModel
  @ObservedObject var session: ChatSession
  let messageID: UUID
  let proposal: NoteActionProposal
  let dismissed: Bool
  @State private var showsReview = false
  @State private var savedEntry: NotebookEntry?
  @State private var openError: String?
  private var receipt: NoteActionReceipt? { session.receipt(for: proposal) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(proposal.kind.title, systemImage: proposal.relation == nil ? "square.and.pencil" : "link")
        .font(.subheadline.weight(.medium))
      if let target = proposal.target {
        Text(target.day).font(.caption).foregroundStyle(.secondary)
        Text(target.snippet).font(.caption).lineLimit(2)
      }
      if let receipt {
        Label(receipt.status == .undone ? "Change undone" : "Change saved",
          systemImage: receipt.status == .undone ? "arrow.uturn.backward" : "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("note-action-status-" + proposal.id.uuidString)
        if receipt.status == .applied {
          HStack {
            if let source = receipt.savedSource {
              Button("Open note") {
                if let entry = notebook.entries.first(where: { $0.id == source.cardRef }) { savedEntry = entry }
                else { openError = String(localized: "This note is no longer available. The change receipt has been kept.") }
              }.frame(minHeight: 44).accessibilityIdentifier("note-action-open-" + proposal.id.uuidString)
            }
            Button("Undo change") {
              Task { await session.confirm(proposal, messageID: messageID, notebook: notebook, undo: true) }
            }.frame(minHeight: 44).disabled(!session.canReviewActions)
              .accessibilityIdentifier("note-action-undo-" + proposal.id.uuidString)
          }.font(.caption)
        }
      } else if dismissed {
        Text("Proposal cancelled").font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("note-action-cancelled-" + proposal.id.uuidString)
      } else {
        Button("Review change") { showsReview = true }
          .font(.subheadline).frame(minHeight: 44).disabled(!session.canReviewActions)
          .accessibilityIdentifier("note-action-review-" + proposal.kind.toolName + "-" + proposal.id.uuidString)
        Text("Nothing changes until you confirm.").font(.caption).foregroundStyle(.secondary)
      }
      if session.applyingProposal == proposal.id { ProgressView().controlSize(.small) }
      if let openError { Text(openError).font(.caption).foregroundStyle(.secondary) }
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(NotebookTheme.card, in: RoundedRectangle(cornerRadius: 12))
      .sheet(isPresented: $showsReview) {
        NoteActionReview(session: session, messageID: messageID, proposal: proposal)
          .environmentObject(notebook)
      }
      .sheet(item: $savedEntry) { entry in
        NavigationStack {
          NoteDetailView(entry: entry).toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { savedEntry = nil } }
          }
        }
      }
  }
}

private struct NoteActionReview: View {
  @EnvironmentObject private var notebook: NotebookModel
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var session: ChatSession
  let messageID: UUID
  let proposal: NoteActionProposal
  @State private var endpoint: NotebookEntry?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text("Review the exact change before saving. Your other notes and capture draft are kept.")
            .font(.subheadline).foregroundStyle(.secondary)
          if let target = proposal.target { source(target) }
          details
          if let error = session.actionError {
            Text(error).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("note-action-error")
          }
          Button {
            Task {
              if await session.confirm(proposal, messageID: messageID, notebook: notebook) { dismiss() }
            }
          } label: {
            HStack {
              if session.applyingProposal == proposal.id { ProgressView() }
              Text("Confirm change")
            }.frame(maxWidth: .infinity, minHeight: 44)
          }.buttonStyle(.borderedProminent).disabled(!session.canReviewActions)
            .accessibilityIdentifier("note-action-confirm")
          Button("Cancel proposal") {
            Task { await session.dismissProposal(proposal, messageID: messageID); dismiss() }
          }.frame(maxWidth: .infinity, minHeight: 44).disabled(!session.canReviewActions)
            .accessibilityIdentifier("note-action-cancel")
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }.accessibilityIdentifier("note-action-review-scroll")
        .notebookSurface().navigationTitle(proposal.kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(session.applyingProposal != nil)
          }
        }
    }.interactiveDismissDisabled(session.applyingProposal != nil)
      .sheet(item: $endpoint) { entry in
        NavigationStack {
          NoteDetailView(entry: entry).toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { endpoint = nil } }
          }
        }
      }
  }

  @ViewBuilder private var details: some View {
    switch proposal.kind {
    case .create:
      section("New note", proposal.body ?? "")
    case .append:
      section("Append this text", proposal.body ?? "")
    case .patch:
      section("Replace this text", proposal.before ?? "")
      section("With this text", proposal.after ?? "")
    case .setTags:
      section("New tags", (proposal.tags ?? []).map { "#" + $0 }.joined(separator: " "))
      Text("Existing hashtags will be replaced. The rest of the note is kept.").font(.footnote).foregroundStyle(.secondary)
    case .setPin:
      Text(proposal.pinned == true ? "Pin this note" : "Unpin this note")
    case .link, .unlink:
      if let relation = proposal.relation {
        Text(relation.type.title).font(.headline)
        source(relation.from)
        Label("To", systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary)
        source(relation.to)
        section("Suggested explanation", relation.reason)
        Text(proposal.kind == .link
          ? "This interpretation becomes a saved connection only after you confirm. Both notes remain unchanged."
          : "Only this saved connection will be removed. Both notes remain unchanged.")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  private func section(_ title: LocalizedStringKey, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func source(_ source: NoteToolSource) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(source.day).font(.caption).foregroundStyle(.secondary)
      Text(source.snippet).font(.body).textSelection(.enabled)
      Button("Open original") {
        if let entry = notebook.entries.first(where: { $0.id == source.cardRef }) { endpoint = entry }
      }.font(.caption).frame(minHeight: 44)
        .disabled(!notebook.entries.contains(where: { $0.id == source.cardRef }))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
