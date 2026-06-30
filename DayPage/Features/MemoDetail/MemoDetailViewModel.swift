import Foundation
import DayPageModels
import DayPageServices

// MARK: - MemoDetailViewModel

/// Protocol abstracting the edit / delete operations that MemoDetailView needs.
/// Both TodayViewModel (live day) and ArchiveMemoViewModel (past dates) conform.
protocol MemoDetailViewModel: AnyObject {
    /// Replace the body of an existing memo and persist to disk.
    func update(memo: Memo, body: String)
    /// Remove a memo and persist to disk.
    func deleteMemo(_ memo: Memo)
}
