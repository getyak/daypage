import Foundation

extension TimeInterval {
    var mmss: String {
        let t = Int(self)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

extension Int {
    var mmss: String {
        String(format: "%02d:%02d", self / 60, self % 60)
    }
}
