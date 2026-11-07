import Foundation

/// Public, inert text only. This model has no connection to notebook state.
struct AppInformation: Decodable {
  struct Section: Decodable {
    let title: String
    let paragraphs: [String]
  }
  struct Language: Decodable {
    let about: [Section]
    let privacy: [Section]
    let support: [Section]
  }
  let schemaVersion: Int
  let appID: String
  let revisionDate: String
  let languages: [String: Language]

  static func decode(_ data: Data) throws -> AppInformation {
    guard data.count <= 128 * 1024 else { throw AppInformationError.tooLarge }
    let value = try JSONDecoder().decode(Self.self, from: data)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard value.schemaVersion == 1, value.appID == "com.daypage.app",
          value.revisionDate.count == 10,
          let date = formatter.date(from: value.revisionDate),
          formatter.string(from: date) == value.revisionDate,
          Set(value.languages.keys) == Set(["en", "zh-Hans"]) else {
      throw AppInformationError.invalidContent
    }
    func plain(_ text: String, limit: Int) -> Bool {
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit &&
        !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" }
    }
    for language in value.languages.values {
      for sections in [language.about, language.privacy, language.support] {
        guard (1...32).contains(sections.count) else { throw AppInformationError.invalidContent }
        for section in sections {
          guard plain(section.title, limit: 120), (1...16).contains(section.paragraphs.count),
                section.paragraphs.allSatisfy({ plain($0, limit: 4000) }) else {
            throw AppInformationError.invalidContent
          }
        }
      }
    }
    return value
  }

  static func bundled(in bundle: Bundle = .main) -> AppInformation {
    if let url = bundle.url(forResource: "app-info", withExtension: "json"),
       let data = try? Data(contentsOf: url), let value = try? decode(data) { return value }
    // A packaging fault must still leave a readable local explanation and support path.
    let en = Language(
      about: [Section(title: "DayPage", paragraphs: ["An account-free local notebook."])],
      privacy: [Section(title: "Privacy", paragraphs: [
        "Notes and attachments are stored in app files. Optional personal iCloud copies notes and attachments through your Apple account; paired Watch capture uses Apple connectivity. No notes are sent to the public information service.",
        "AI and external speech contact your configured provider only when requested. AI note changes require native preview and confirmation. Keys stay in Keychain. Feedback shared with GitHub may be public.",
        "Export a backup before uninstalling. Exports, Apple backups and provider copies need separate management. The complete bundled policy could not be loaded; use Feedback for help."
      ])],
      support: [Section(title: "Support", paragraphs: ["Open Feedback in the sidebar. Include the app/iOS version and reproduction steps, without private notes or keys."])])
    let zh = Language(
      about: [Section(title: "DayPage", paragraphs: ["无需账户的本地笔记应用。可离线记录与阅读。 "])],
      privacy: [Section(title: "隐私", paragraphs: [
        "笔记和附件保存在应用文件中。可选个人 iCloud 通过你的 Apple 账户复制笔记和附件；配对 Watch 通过 Apple 连接传递记录。公开说明服务不接收笔记。",
        "AI 和外部朗读仅在主动使用时联系你配置的服务。AI 修改笔记需要原生预览与确认。密钥保存在 Keychain。分享到 GitHub 的反馈可能公开。",
        "卸载前请导出备份。导出、Apple 备份和服务商副本需分别管理。完整内置政策暂时无法载入，可通过反馈寻求帮助。"
      ])],
      support: [Section(title: "支持", paragraphs: ["从侧栏打开反馈，提供应用和 iOS 版本、复现步骤；请勿附上私密笔记或密钥。 "])])
    return Self(schemaVersion: 1, appID: "com.daypage.app", revisionDate: "2026-11-07",
                languages: ["en": en, "zh-Hans": zh])
  }
}

enum AppInformationError: Error, Equatable { case invalidContent, invalidResponse, tooLarge, redirected }

struct AppInformationService {
  private let configuration: URLSessionConfiguration
  private let now: @Sendable () -> ContinuousClock.Instant
  init(configuration: URLSessionConfiguration = .ephemeral,
       now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }) {
    // Copy only the transport adapter; never inherit another feature's headers/storage.
    let clean = URLSessionConfiguration.ephemeral
    clean.protocolClasses = configuration.protocolClasses
    clean.httpCookieStorage = nil
    clean.httpShouldSetCookies = false
    clean.urlCredentialStorage = nil
    clean.urlCache = nil
    clean.requestCachePolicy = .reloadIgnoringLocalCacheData
    clean.timeoutIntervalForRequest = 8
    clean.timeoutIntervalForResource = 8
    clean.httpAdditionalHeaders = [:]
    self.configuration = clean
    self.now = now
  }

  func fetch() async throws -> AppInformation {
    let transfer = AppInformationTransfer(configuration: configuration, now: now)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { transfer.start($0) }
    } onCancel: { transfer.cancel() }
  }
}

private final class AppInformationTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let lock = NSLock()
  private var continuation: CheckedContinuation<AppInformation, Error>?
  private var terminal: Result<AppInformation, Error>?
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var deadline: DispatchWorkItem?
  private var expiresAt: ContinuousClock.Instant?
  // These fields are touched only by the session's serial delegate queue.
  private var data = Data()
  private var acceptedResponse = false

  init(configuration: URLSessionConfiguration, now: @escaping @Sendable () -> ContinuousClock.Instant) {
    self.configuration = configuration
    self.now = now
  }

  func start(_ continuation: CheckedContinuation<AppInformation, Error>) {
    lock.lock()
    if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
    self.continuation = continuation
    expiresAt = now().advanced(by: .seconds(8))
    guard let url = URL(string: "https://daypage-api.cubxxw.com/daypage/v1/app-info.json") else {
      lock.unlock(); finish(.failure(AppInformationError.invalidResponse)); return
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(with: request)
    self.task = task
    let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
    self.deadline = deadline
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: deadline)
    task.resume()
    lock.unlock()
  }

  func cancel() { finish(.failure(CancellationError())) }

  private func finish(_ result: Result<AppInformation, Error>) {
    lock.lock()
    guard terminal == nil else { lock.unlock(); return }
    // The watchdog releases silent transports; this independent monotonic check
    // also rejects a decode/completion finishing late while that queue is delayed.
    let admitted: Result<AppInformation, Error>
    if case .success = result, let expiresAt, now() >= expiresAt {
      admitted = .failure(URLError(.timedOut))
    } else { admitted = result }
    terminal = admitted
    let continuation = self.continuation
    self.continuation = nil
    let session = self.session
    self.session = nil
    task = nil
    deadline?.cancel()
    deadline = nil
    lock.unlock()
    session?.invalidateAndCancel()
    continuation?.resume(with: admitted)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
          response.mimeType?.lowercased() == "application/json" else {
      completionHandler(.cancel); finish(.failure(AppInformationError.invalidResponse)); return
    }
    guard response.expectedContentLength <= 128 * 1024 else {
      completionHandler(.cancel); finish(.failure(AppInformationError.tooLarge)); return
    }
    acceptedResponse = true
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    guard chunk.count <= 128 * 1024 - data.count else {
      finish(.failure(AppInformationError.tooLarge)); return
    }
    data.append(chunk)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)); return }
    guard acceptedResponse else { finish(.failure(AppInformationError.invalidResponse)); return }
    finish(Result { try AppInformation.decode(data) })
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
    finish(.failure(AppInformationError.redirected))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // System trust evaluation remains intact; never answer HTTP authentication.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else { completionHandler(.cancelAuthenticationChallenge, nil) }
  }
}
