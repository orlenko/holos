import Foundation

extension ReadingLibrary {
    /// What the app does with the list it loaded at launch: the readings whose deletion a quit interrupted (to
    /// finish deleting), the list without them after `afterLaunch`, and the readings to continue. A list a newer
    /// build wrote (`writable` false) is shown exactly as loaded: nothing is deleted, changed, or continued.
    public static func launchPlan(_ loaded: ReadingLibraryStore.Loaded)
        -> (entries: [ReadingEntry], resume: [UUID], delete: [ReadingEntry]) {
        guard loaded.writable else { return (loaded.entries, [], []) }
        let delete = loaded.entries.filter { $0.deletePending == true }
        let (entries, resume) = afterLaunch(loaded.entries.filter { $0.deletePending != true })
        return (entries, resume, delete)
    }

    /// The list as the app finds it at launch (a reading marked for deletion is left as it is, for the caller to
    /// finish deleting): a reading that was waiting or being made when Voice is Local quit
    /// continues when the user chose Keep Rendering (`resumeOnLaunch`; it is returned in `resume`: the one that was
    /// being made first, then the waiting ones oldest first, as they were asked for), and is otherwise shown as
    /// stopped, with Resume. `resumeOnLaunch` is used once.
    public static func afterLaunch(_ entries: [ReadingEntry]) -> (entries: [ReadingEntry], resume: [UUID]) {
        var result = entries
        var first: [ReadingEntry] = [], rest: [ReadingEntry] = []
        for index in result.indices where result[index].isActive && result[index].deletePending != true {
            if result[index].resumeOnLaunch {
                if result[index].state == .rendering { first.append(result[index]) } else { rest.append(result[index]) }
                result[index].state = .queued
            } else {
                result[index].state = .stopped
                result[index].message = "Voice is Local quit while this reading was being made."
            }
            result[index].resumeOnLaunch = false
        }
        let order = { (lhs: ReadingEntry, rhs: ReadingEntry) in lhs.created < rhs.created }
        return (result, (first.sorted(by: order) + rest.sorted(by: order)).map(\.id))
    }

    /// A reading whose deletion could not remove its files, back in the list: unmarked, with the reason, and, when it
    /// was waiting or being made (its render has stopped by then), stopped and never continued at a launch.
    /// `aside`: where its file was left, when it was moved aside and could not be put back (see `DeleteResult`).
    public static func afterFailedDelete(_ entry: ReadingEntry, problem: String, aside: String? = nil) -> ReadingEntry {
        var entry = entry
        entry.deletePending = nil
        entry.message = problem
        entry.outputAside = aside
        entry.resumeOnLaunch = false
        if entry.isActive { entry.state = .stopped }
        return entry
    }

    /// The list as saved when Voice is Local quits with readings waiting or being made: `keep` (Keep Rendering)
    /// continues them at the next launch; otherwise (Stop) they are stopped, each with Resume.
    public static func forQuit(_ entries: [ReadingEntry], keep: Bool) -> [ReadingEntry] {
        entries.map { entry in
            guard entry.isActive else { return entry }
            var entry = entry
            if keep {
                entry.resumeOnLaunch = true
            } else {
                entry.state = .stopped
                entry.message = "Stopped when Voice is Local quit."
                entry.resumeOnLaunch = false
            }
            return entry
        }
    }
}
