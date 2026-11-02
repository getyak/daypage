import Foundation

public struct ChatCharacter: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var role: String
  public var soul: String
  public init(id: UUID = UUID(), name: String, role: String = "", soul: String = "") {
    self.id = id; self.name = name; self.role = role; self.soul = soul
  }
  public var isValid: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && name.count <= 80 && role.count <= 240 && soul.count <= 8000
  }
  public static let companion = ChatCharacter(
    id: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1)), name: "DayPage",
    role: "A thoughtful companion",
    soul: "Be curious, patient and candid. Use plain, natural conversation in the user's language. Do not flatter or invent feelings, experiences or memories. Offer a useful observation; ask one question only when needed. Let the user guide depth.")
}

public struct ChatHistory: Sendable {
  public let conversations: [Conversation]
  public let unreadableCount: Int
}
