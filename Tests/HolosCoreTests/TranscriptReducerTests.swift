import Testing
@testable import HolosCore

@Test func replacingProvisionalTextDoesNotDuplicateWords() throws {
    var reducer = TranscriptReducer()
    try reducer.apply(.init(segment: .init(start: 0, end: 1, text: "hello"), isFinal: false))
    try reducer.apply(.init(segment: .init(start: 0, end: 2, text: "hello world"), isFinal: true))
    #expect(reducer.provisional.isEmpty)
    #expect(reducer.finalized.map(\.text) == ["hello world"])
}

@Test func finalizedTextCannotBeSilentlyReplaced() throws {
    var reducer = TranscriptReducer()
    try reducer.apply(.init(segment: .init(start: 0, end: 1, text: "hello"), isFinal: true))
    #expect(throws: HolosError.self) {
        try reducer.apply(.init(segment: .init(start: 0, end: 1, text: "goodbye"), isFinal: true))
    }
}

@Test func invalidAudioFramesAreRejected() {
    #expect(throws: HolosError.self) {
        try PCMFrame(samples: [0], sampleRate: 48000, channels: 2, startTime: 0)
    }
}
