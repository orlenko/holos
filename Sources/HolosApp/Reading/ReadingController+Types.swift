import Foundation

extension ReadingController {
    /// What a reading being made is doing, for its row.
    enum Activity: Equatable {
        case loading
        case rendering(part: Int, of: Int)
        case joining(parts: Int)
    }

    /// What a Delete came to.
    enum DeleteOutcome: Equatable {
        /// The reading is deleted (or will be once its render has stopped); `note` is something the user should know
        /// (its file had changed, so it was left in place).
        case deleted(note: String?)
        /// The reading stays in the list, for the reason given.
        case kept(String)
    }
}
