import Foundation
import HolosCore
import Testing
@testable import HolosAppModel

@Test func declinedQueueKeepsEveryPairUntilAddedOrSkipped() {
    var queue = DeclinedCorrectionQueue()
    queue.receive([.init(heard: "Bull", meant: "Pull"), .init(heard: "Male", meant: "Mail")])
    // A later Learn adds behind the waiting pairs; a repeated phrase is replaced in place.
    queue.receive([.init(heard: "bull", meant: "Poll"), .init(heard: "Tail", meant: "Tale")])
    #expect(queue.pending == [.init(heard: "bull", meant: "Poll"), .init(heard: "Male", meant: "Mail"),
                              .init(heard: "Tail", meant: "Tale")])

    // Pre-fill only when both fields are blank, so a half-typed manual correction survives.
    #expect(queue.prefill(heard: "", meant: " ") == .init(heard: "bull", meant: "Poll"))
    #expect(queue.prefill(heard: "clod", meant: "") == nil)
    #expect(queue.prefill(heard: "", meant: "cloud") == nil)

    // Adding any rule for a waiting phrase resolves it, even with an edited meant text.
    let resolvedEdited = queue.resolve(added: .init(heard: "BULL", meant: "pole"))
    let resolvedUnrelated = queue.resolve(added: .init(heard: "clod", meant: "cloud"))
    #expect(resolvedEdited?.correction == .init(heard: "bull", meant: "Poll"))
    #expect(resolvedUnrelated == nil)
    #expect(queue.prefill(heard: "", meant: "") == .init(heard: "Male", meant: "Mail"))

    let skipped = queue.skip()
    #expect(skipped == .init(heard: "Male", meant: "Mail"))
    #expect(queue.pending == [.init(heard: "Tail", meant: "Tale")])
    let resolvedLast = queue.resolve(added: .init(heard: "Tail", meant: "Tale"))
    #expect(resolvedLast != nil)
    #expect(queue.isEmpty)
    let skippedEmpty = queue.skip()
    #expect(skippedEmpty == nil)
    #expect(queue.prefill(heard: "", meant: "") == nil)
}

@Test func declinedSwapKeepsOnlyTheEditItCameFrom() {
    // Dictation A's edit declined "Bull"; dictation B's edit then declined "Male" while "Bull" still waits.
    let editA = DeclinedCorrectionQueue.PendingEdit(recognized: "Bull request", edited: "Pull request")
    let editB = DeclinedCorrectionQueue.PendingEdit(recognized: "Male sent", edited: "Mail sent")
    var queue = DeclinedCorrectionQueue()
    queue.receive([.init(heard: "Bull", meant: "Pull")], edit: editA)
    queue.receive([.init(heard: "Male", meant: "Mail")], edit: editB)
    var lastRecognized = editB.recognized

    // Adding A's swap must not keep B's edit, and must leave B's edit waiting on B's swap.
    let resolvedA = queue.resolve(added: .init(heard: "Bull", meant: "Pull"))
    #expect(resolvedA?.edit == editA)
    #expect(resolvedA?.edit?.transcript(whenLastRecognized: lastRecognized) == nil)

    let resolvedB = queue.resolve(added: .init(heard: "Male", meant: "Mail"))
    #expect(resolvedB?.edit == editB)
    let kept = resolvedB?.edit?.transcript(whenLastRecognized: lastRecognized)
    #expect(kept == "Mail sent")
    lastRecognized = kept ?? lastRecognized

    // A second swap from an edit already kept does not keep it again.
    #expect(editB.transcript(whenLastRecognized: lastRecognized) == nil)
    // A newer Learn of the same phrase carries the newer edit.
    queue.receive([.init(heard: "bull", meant: "Pull")], edit: editA)
    queue.receive([.init(heard: "Bull", meant: "Pull")], edit: editB)
    #expect(queue.items == [.init(correction: .init(heard: "Bull", meant: "Pull"), edit: editB)])
}

@Test func pendingEditKeepsOnlyForTheDictationItCameFrom() {
    // An older dictation with the same text as the last one is a different dictation.
    let last = UUID(), older = UUID()
    let edit = DeclinedCorrectionQueue.PendingEdit(recognized: "Bull request", edited: "Pull request",
                                                   dictation: older)
    #expect(edit.transcript(for: last, whenLastRecognized: "Bull request") == nil)
    #expect(edit.transcript(for: older, whenLastRecognized: "Bull request") == "Pull request")
    #expect(edit.transcript(for: older, whenLastRecognized: "Something newer") == nil)
    #expect(edit.transcript(for: nil, whenLastRecognized: "Bull request") == nil)
    let unidentified = DeclinedCorrectionQueue.PendingEdit(recognized: "Bull request", edited: "Pull request")
    #expect(unidentified.transcript(for: last, whenLastRecognized: "Bull request") == nil)
}
