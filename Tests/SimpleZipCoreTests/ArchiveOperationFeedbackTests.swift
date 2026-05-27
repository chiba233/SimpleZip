import Testing
@testable import SimpleZipCore

struct ArchiveOperationFeedbackTests {
    @Test
    func failureAlertKeepsShortMessageUntouched() {
        let alert = ArchiveOperationFailureAlert(message: "Wrong password")

        #expect(alert.previewMessage == "Wrong password")
        #expect(alert.fullMessage == "Wrong password")
    }

    @Test
    func failureAlertTruncatesLongMessageForAlertPreview() {
        let message = String(repeating: "a", count: 605)
        let alert = ArchiveOperationFailureAlert(message: message)

        #expect(alert.previewMessage.count == 602)
        #expect(alert.previewMessage.hasSuffix("\n…"))
        #expect(alert.fullMessage == message)
    }
}
