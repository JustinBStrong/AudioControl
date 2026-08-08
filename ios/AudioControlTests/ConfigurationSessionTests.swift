import XCTest
@testable import AudioControl

final class ConfigurationSessionTests: XCTestCase {
    func testDisconnectedSessionIsLockedAndLabelsValuesAsUnconfirmed() {
        let session = ConfigurationSession()

        XCTAssertFalse(session.canEdit)
        XCTAssertFalse(session.canApply)
        XCTAssertEqual(session.state, .disconnected(lastSavedRevision: nil))
    }

    func testControlsUnlockOnlyAfterAuthoritativeConfigurationIsRead() {
        var session = ConfigurationSession()
        session.beginReading()
        XCTAssertFalse(session.canEdit)
        XCTAssertEqual(session.state, .reading)

        session.receive(configuration: configuration(revision: 41, delay: 212.7))

        XCTAssertFalse(session.canEdit)
        XCTAssertEqual(session.draft.delayMilliseconds, 212.7)
        XCTAssertEqual(session.state, .verifying(revision: 41))

        session.receive(telemetry: telemetry(revision: 41, dirty: false))
        XCTAssertTrue(session.canEdit)
        XCTAssertEqual(session.state, .confirmed(revision: 41))
        XCTAssertEqual(session.lastSaved?.revision, 41)
    }

    func testEditingCreatesLocalDraftWithoutChangingRevision() {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)

        XCTAssertEqual(session.draft.revision, 41)
        XCTAssertEqual(session.authoritative?.delayMilliseconds, 212.7)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.canApply)
        XCTAssertTrue(session.canEdit)
        XCTAssertEqual(session.state, .edited(savedRevision: 41))
    }

    func testApplyUsesOneNewRevisionAndWaitsForAllConfirmations() throws {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)

        let request = try XCTUnwrap(session.beginApply())
        XCTAssertEqual(request.revision, 42)
        XCTAssertEqual(session.state, .sending(revision: 42))
        XCTAssertFalse(session.canEdit)

        session.receiveWriteCompletion(revision: 42, errorMessage: nil)
        session.receive(status: CommandStatus(status: 0, requestID: 42))
        session.receive(configuration: request)
        session.receive(telemetry: telemetry(revision: 42, dirty: true))
        XCTAssertEqual(session.state, .saving(revision: 42))
        XCTAssertEqual(session.lastSaved?.revision, 41)

        session.receive(telemetry: telemetry(revision: 42, dirty: false))
        XCTAssertEqual(session.state, .confirmed(revision: 42))
        XCTAssertEqual(session.lastSaved?.delayMilliseconds, 205.0)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertTrue(session.canEdit)
    }

    func testConfirmationEventsMayArriveOutOfOrder() throws {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)
        let request = try XCTUnwrap(session.beginApply())

        session.receive(telemetry: telemetry(revision: 42, dirty: false))
        session.receive(configuration: request)
        session.receive(status: CommandStatus(status: 0, requestID: 42))

        XCTAssertEqual(session.state, .saving(revision: 42))
        XCTAssertFalse(session.canEdit)

        session.receiveWriteCompletion(revision: 42, errorMessage: nil)

        XCTAssertEqual(session.state, .confirmed(revision: 42))
        XCTAssertEqual(session.lastSaved?.delayMilliseconds, 205.0)
        XCTAssertTrue(session.canEdit)
    }

    func testStaleNotificationCannotOverwritePendingDraft() throws {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)
        _ = try XCTUnwrap(session.beginApply())

        session.receive(configuration: configuration(revision: 41, delay: 212.7))

        XCTAssertEqual(session.draft.delayMilliseconds, 205.0)
        XCTAssertEqual(session.pendingRevision, 42)
        XCTAssertEqual(session.state, .sending(revision: 42))
    }

    func testWriteFailureKeepsDraftButIdentifiesSavedRevision() throws {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)
        _ = try XCTUnwrap(session.beginApply())

        session.receiveWriteCompletion(revision: 42, errorMessage: "Bluetooth disconnected.")

        XCTAssertEqual(
            session.state,
            .failed(message: "Bluetooth disconnected.", savedRevision: 41)
        )
        XCTAssertEqual(session.draft.delayMilliseconds, 205.0)
        XCTAssertEqual(session.authoritative?.delayMilliseconds, 212.7)
        XCTAssertFalse(session.canApply)
        XCTAssertFalse(session.canEdit)
    }

    func testDisconnectRestoresLastConfirmedValuesAndLocksControls() {
        var session = confirmedSession(revision: 41)
        var draft = session.draft
        draft.delayMilliseconds = 205.0
        session.replaceDraft(draft)

        session.disconnect()

        XCTAssertEqual(session.draft.delayMilliseconds, 212.7)
        XCTAssertEqual(session.state, .disconnected(lastSavedRevision: 41))
        XCTAssertFalse(session.canEdit)
    }

    private func confirmedSession(revision: UInt32) -> ConfigurationSession {
        var session = ConfigurationSession()
        session.beginReading()
        session.receive(configuration: configuration(revision: revision, delay: 212.7))
        session.receive(telemetry: telemetry(revision: revision, dirty: false))
        return session
    }

    private func configuration(revision: UInt32, delay: Double) -> DSPConfiguration {
        DSPConfiguration(
            revision: revision,
            delayMilliseconds: delay,
            lowPassHz: 80,
            outputGainDB: 0,
            delayEnabled: true,
            lowPassEnabled: true,
            dspBypassed: false,
            bassShelf: BassShelfConfiguration()
        )
    }

    private func telemetry(revision: UInt32, dirty: Bool) -> AudioTelemetry {
        AudioTelemetry(
            codecReady: true,
            audioRunning: true,
            inputClipped: false,
            outputClipped: false,
            underrunDetected: false,
            settingsDirty: dirty,
            configurationRevision: revision,
            inputPeakLeftDBFS: -40,
            inputPeakRightDBFS: -40,
            outputPeakLeftDBFS: -40,
            outputPeakRightDBFS: -40,
            underrunCount: 0
        )
    }
}
