@testable import HolosMeeting
import Testing

// Which background job goes next among the ones the kinds would start (docs/meeting-design.md §4.17, §5.11). Pure.

@Test func askedForWorkGoesFirstThenCatchUpThenAutomaticWork() {
    #expect(BackgroundJobOrder.next([.automatic, .catchUp, .askedFor], .init()) == 2)
    #expect(BackgroundJobOrder.next([.automatic, .catchUp], .init()) == 1)
    #expect(BackgroundJobOrder.next([.automatic], .init()) == 0)
    #expect(BackgroundJobOrder.next([.automatic, .automatic], .init()) == 0, "Kinds in their order.")
    #expect(BackgroundJobOrder.next([], .init()) == nil)
}

@Test func nothingStartsWhileAMeetingOrAnotherJobHoldsTheMac() {
    for priority in [BackgroundJobPriority.askedFor, .catchUp, .automatic] {
        #expect(BackgroundJobOrder.next([priority], .init(blocked: true)) == nil)
    }
}

@Test func askedForWorkWaitsForNothingElse() {
    let everything = BackgroundJobOrder.Situation(askedForWaiting: true, summaryRequestScan: true,
                                                  catchUpPending: true)
    #expect(BackgroundJobOrder.next([.catchUp, .askedFor], everything) == 1)
}

@Test func catchUpWorkWaitsForAskedForWorkAndASummarizeAgainScan() {
    #expect(BackgroundJobOrder.next([.catchUp], .init(askedForWaiting: true)) == nil)
    #expect(BackgroundJobOrder.next([.catchUp], .init(summaryRequestScan: true)) == nil)
    #expect(BackgroundJobOrder.next([.catchUp], .init(catchUpPending: true)) == 0, "Its own scan does not hold it.")
    // Automatic work waits while catch-up work waits.
    #expect(BackgroundJobOrder.next([.automatic, .catchUp], .init(askedForWaiting: true)) == nil)
}

@Test func automaticWorkWaitsForASummarizeAgainScanAndAnUnknownCatchUpQueue() {
    #expect(BackgroundJobOrder.next([.automatic], .init(summaryRequestScan: true)) == nil)
    #expect(BackgroundJobOrder.next([.automatic], .init(catchUpPending: true)) == nil)
    // Asked-for work that cannot start yet (its languages are being read) does not hold it back.
    #expect(BackgroundJobOrder.next([.automatic], .init(askedForWaiting: true)) == 0)
}
