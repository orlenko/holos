import Foundation
import Testing
@testable import HolosDesktop

@Test func boundedFingerprintUsesUTF16AndKeepsComposedText() throws {
    let value = "A👩🏽‍💻B café"
    let emoji = "👩🏽‍💻"
    let selection = NSRange(location: 1, length: emoji.utf16.count)
    let window = try #require(InsertionPolicy.window(selection: selection, totalLength: value.utf16.count))
    #expect(window.location == 0)
    #expect(window.length == value.utf16.count)
    #expect((value as NSString).substring(with: selection) == emoji)
    #expect(InsertionPolicy.fingerprint(value) == InsertionPolicy.fingerprint(String(value)))
    #expect(InsertionPolicy.window(selection: NSRange(location: 2, length: 300),
                                   totalLength: value.utf16.count) == nil)
}

@Test func focusSelectionContextAndSecureChangesBlockInsertion() {
    let baseline = InsertionSnapshot(pid: 100, selection: NSRange(location: 3, length: 0),
                                     totalUTF16Length: 12, window: NSRange(location: 0, length: 12),
                                     fingerprint: InsertionPolicy.fingerprint("hello world!"), secure: false)
    #expect(InsertionPolicy.matches(baseline, baseline))
    #expect(!InsertionPolicy.matches(baseline, InsertionSnapshot(pid: 101, selection: baseline.selection,
        totalUTF16Length: 12, window: baseline.window, fingerprint: baseline.fingerprint, secure: false)))
    #expect(!InsertionPolicy.matches(baseline, InsertionSnapshot(pid: 100, selection: NSRange(location: 4, length: 0),
        totalUTF16Length: 12, window: baseline.window, fingerprint: baseline.fingerprint, secure: false)))
    #expect(!InsertionPolicy.matches(baseline, InsertionSnapshot(pid: 100, selection: baseline.selection,
        totalUTF16Length: 12, window: baseline.window, fingerprint: InsertionPolicy.fingerprint("hello there!"), secure: false)))
    #expect(!InsertionPolicy.matches(baseline, InsertionSnapshot(pid: 100, selection: baseline.selection,
        totalUTF16Length: 12, window: baseline.window, fingerprint: baseline.fingerprint, secure: true)))
}

@Test func controlCharactersRequireExplicitCopy() {
    #expect(InsertionPolicy.permits("Hello, café 👩🏽‍💻"))
    #expect(!InsertionPolicy.permits(""))
    #expect(!InsertionPolicy.permits("run command\n"))
    #expect(!InsertionPolicy.permits("line\rreturn"))
    #expect(!InsertionPolicy.permits("column\tdata"))
    #expect(!InsertionPolicy.permits("line\u{2028}separator"))
}
