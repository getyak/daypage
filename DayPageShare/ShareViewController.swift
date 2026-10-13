import UIKit
import UniformTypeIdentifiers
import DayPageServices

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var hasStarted = false
    /// Cancellation must win against the item-provider callback: marking is
    /// synchronous so no staging can start after the user taps Cancel.
    private let stagingGate = ScreenshotShareStagingGate()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "保存到 DayPage"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        statusLabel.text = "正在接收截图…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, spinner, statusLabel, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        receiveFirstImage()
    }

    @objc private func cancel() {
        stagingGate.cancel()
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    private func receiveFirstImage() {
        let extensionItems = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem } ?? []
        let providers = extensionItems.flatMap { $0.attachments ?? [] }
        guard
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let contentType = preferredContentType(from: provider) else {
            finishWithError("请选择一张 PNG 或 JPEG 截图")
            return
        }

        provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { [weak self] data, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    self.finishWithError("读取截图失败：\(error.localizedDescription)")
                }
                return
            }
            guard let data else {
                Task { @MainActor in self.finishWithError("截图文件为空") }
                return
            }

            Task {
                do {
                    let staged = try await self.stagingGate.stageIfActive(
                        in: ScreenshotShareInbox.shared,
                        data: data,
                        declaredContentType: contentType.identifier
                    )
                    guard staged != nil else {
                        // The user cancelled while staging: nothing was left
                        // behind and the host already received the cancel.
                        return
                    }
                    await self.finishSuccessfully()
                } catch {
                    await self.finishWithError(error.localizedDescription)
                }
            }
        }
    }

    private func preferredContentType(from provider: NSItemProvider) -> UTType? {
        let registered = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        if registered.contains(where: { $0.conforms(to: .png) }) { return .png }
        if registered.contains(where: { $0.conforms(to: .jpeg) }) { return .jpeg }
        return nil
    }

    @MainActor
    private func finishSuccessfully() {
        spinner.stopAnimating()
        statusLabel.text = "已送入 DayPage 收件箱\n下次打开 DayPage 会自动完成本机识别"
        statusLabel.textColor = .label
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    @MainActor
    private func finishWithError(_ message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed
    }
}
