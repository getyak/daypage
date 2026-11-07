import DayPageCapture
import UIKit
import UniformTypeIdentifiers

/// This target can only stage an image. It never opens or writes the notebook.
@MainActor
final class ShareViewController: UIViewController {
  private let status = UILabel()
  private let add = UIButton(type: .system)
  private let cancel = UIButton(type: .system)
  private var cancelled = false
  private var publishing = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    isModalInPresentation = true
    let title = UILabel()
    title.text = String(localized: "Add image to DayPage")
    title.font = .preferredFont(forTextStyle: .title2)
    title.adjustsFontForContentSizeCategory = true
    title.numberOfLines = 0
    status.text = String(localized: "Open DayPage afterwards to review the image and choose Save note. Nothing is sent to AI.")
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    add.setTitle(String(localized: "Add image"), for: .normal)
    add.addTarget(self, action: #selector(stageImage), for: .touchUpInside)
    cancel.setTitle(String(localized: "Cancel"), for: .normal)
    cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [title, status, add, cancel])
    stack.axis = .vertical; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      add.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
    ])
    preferredContentSize = CGSize(width: 420, height: 340)
  }

  @objc private func cancelShare() {
    // The only non-cancellable interval is the short atomic local publication,
    // after the Add gesture. Cancel stays available while a provider is loading.
    guard !publishing else { return }
    cancelled = true
    extensionContext?.cancelRequest(withError: CancellationError())
  }

  @objc private func stageImage() {
    guard !cancelled, add.isEnabled else { return }
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let attachments = items.flatMap { $0.attachments ?? [] }
    guard attachments.count == 1, let provider = attachments.first,
      let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      }) else {
      status.text = String(localized: "Choose one PNG, JPEG or HEIC image.")
      return
    }
    add.isEnabled = false
    status.text = String(localized: "Loading image…")
    provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, error in
      // A provider URL is valid only inside this callback. Copy bounded bytes
      // before returning; do not enqueue the ephemeral URL for later reading.
      let result = Result<Data, Error> {
        guard let url, error == nil else { throw ScreenshotInboxError.invalidImage }
        return try ScreenshotInbox.readImageFile(url)
      }
      Task { @MainActor [weak self] in
        guard let self, !self.cancelled else { return }
        do {
          let data = try result.get()
          let inbox = try ScreenshotInboxLocation.make()
          self.publishing = true
          self.cancel.isEnabled = false
          self.status.text = String(localized: "Adding image…")
          _ = try await inbox.stage(data)
          self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        } catch {
          self.publishing = false
          self.cancel.isEnabled = true
          self.add.isEnabled = true
          self.status.text = (error as? ScreenshotInboxError)?.localizedDescription
            ?? String(localized: "The image could not be added. Try again without changing the original.")
        }
      }
    }
  }
}
