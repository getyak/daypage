import SwiftUI

enum NotebookTheme {
  static let paper = Color("NotebookPaper")
  static let card = Color("NotebookCard")
  static let accent = Color("NotebookAccent")
  static let spine = Color("NotebookSpine")
  static let spineTop = Color("NotebookSpineTop")
  static let spineInk = Color("NotebookSpineInk")
  static let spineMuted = Color("NotebookSpineMuted")
  static let spineSelection = Color("NotebookSpineSelection")
  static let gold = Color("NotebookGold")
  static func reading(_ size: CGFloat = 18, text: String? = nil) -> Font {
    let chinese =
      Locale.preferredLanguages.first?.hasPrefix("zh") == true
      || text?.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) == true
    return .custom(
      chinese ? "SourceHanSerifSC-Regular" : "SourceSerif4-Regular", size: size, relativeTo: .body)
  }
}

extension View {
  func notebookSurface() -> some View { background(NotebookTheme.paper.ignoresSafeArea()) }
}
