import Testing
@testable import SimpleZipCore

struct ArchiveOperationFeedbackTests {
    @Test
    func failureAlertKeepsShortMessageUntouched() {
        #expect(ArchiveOperationFailurePreview.truncate("Wrong password") == "Wrong password")
    }

    @Test
    func failureAlertTruncatesLongMessageForAlertPreview() {
        let message = String(repeating: "a", count: 605)
        let preview = ArchiveOperationFailurePreview.truncate(message)

        #expect(preview.count == 602)
        #expect(preview.hasSuffix("\n…"))
    }
}
