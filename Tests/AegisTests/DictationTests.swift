import XCTest
import AppKit
import AVFoundation
import UniformTypeIdentifiers
@testable import Aegis

final class DictationTests: XCTestCase {
    func testDefaultsPreserveExistingPreferences() {
        let name = "AegisDictationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsStore.registerDictationDefaults(defaults)
        XCTAssertFalse(defaults.bool(forKey: "dictationEnabled"))
        XCTAssertFalse(defaults.bool(forKey: "dictationMuteWhileRecording"))
        XCTAssertEqual(defaults.string(forKey: "dictationMode"), "toggle")
        XCTAssertEqual(defaults.string(forKey: "dictationShiftKey"), "either")
        XCTAssertEqual(defaults.string(forKey: "dictationMicrophoneID"), "")
        defaults.set("missing-device", forKey: "dictationMicrophoneID")
        defaults.set("hold", forKey: "dictationMode")
        defaults.set(true, forKey: "dictationEnabled")
        SettingsStore.registerDictationDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: "dictationEnabled"))
        XCTAssertEqual(defaults.string(forKey: "dictationMode"), "hold")
        XCTAssertEqual(defaults.string(forKey: "dictationMicrophoneID"), "missing-device")
    }

    @MainActor
    func testStopDuringMicrophonePreparationAllowsRetryBeforeOldRequestReturns() async {
        _ = NSApplication.shared
        var pending: [CheckedContinuation<Bool, Never>] = []
        let controller = DictationController(settings: SettingsStore(), requestMicrophone: {
            await withCheckedContinuation { pending.append($0) }
        })
        controller.prepareMicrophone()
        while pending.isEmpty { await Task.yield() }
        let oldOperation = controller.operation
        controller.handle(.stop)
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        controller.prepareMicrophone()
        while pending.count < 2 { await Task.yield() }
        let retry = controller.operation
        pending.removeFirst().resume(returning: true)
        await oldOperation?.value
        XCTAssertTrue(controller.requesting, "A late callback must not change the retry")
        XCTAssertNotNil(controller.operation)
        controller.handle(.stop)
        pending.removeFirst().resume(returning: false)
        await retry?.value
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        controller.stop()
    }

    @MainActor
    func testMicrophonePreparationDeadlineReleasesOperationAndAllowsRetry() async throws {
        _ = NSApplication.shared
        var pending: [CheckedContinuation<Bool, Never>] = []
        let settings = SettingsStore()
        let controller = DictationController(settings: settings, preparationLimit: .milliseconds(20), requestMicrophone: {
            await withCheckedContinuation { pending.append($0) }
        })
        controller.prepareMicrophone()
        while pending.isEmpty { await Task.yield() }
        let oldOperation = controller.operation
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.requesting)
        XCTAssertNil(controller.operation)
        XCTAssertTrue(settings.dictationStatus.contains("took too long"))
        controller.prepareMicrophone()
        while pending.count < 2 { await Task.yield() }
        let retry = controller.operation
        XCTAssertTrue(controller.requesting)
        pending.removeFirst().resume(returning: true)
        await oldOperation?.value
        XCTAssertTrue(controller.requesting)
        controller.handle(.stop)
        pending.removeFirst().resume(returning: false)
        await retry?.value
        controller.stop()
    }

    private func tap(_ state: inout DictationShortcutState, key: UInt16 = 56, at time: Double) -> DictationShortcutState.Action? {
        XCTAssertNil(state.shift(code: key, down: true, at: time))
        return state.shift(code: key, down: false, at: time + 0.05)
    }

    func testDoubleTapEitherShiftTogglesStartAndStop() {
        var state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 1))
        XCTAssertEqual(tap(&state, key: 60, at: 1.2), .start)
        XCTAssertTrue(state.recording)
        XCTAssertNil(tap(&state, key: 60, at: 2))
        XCTAssertEqual(tap(&state, key: 60, at: 2.2), .stop)
        XCTAssertFalse(state.recording)
        var press = DictationShortcutState(mode: .press, key: .right)
        XCTAssertEqual(tap(&press, key: 60, at: 1), .start)
        XCTAssertEqual(tap(&press, key: 60, at: 2), .stop)
        XCTAssertNil(tap(&state, at: 3))
        XCTAssertNil(tap(&state, at: 4))
    }

    func testHoldStartsOnceAndStopsOnRelease() {
        var state = DictationShortcutState(mode: .hold, key: .right)
        XCTAssertNil(state.shift(code: 60, down: true, at: 1))
        XCTAssertNil(state.holdElapsed(at: 1.1))
        XCTAssertEqual(state.holdElapsed(at: 1.3), .start)
        XCTAssertNil(state.shift(code: 60, down: true, at: 1.4))
        XCTAssertNil(state.holdElapsed(at: 1.5))
        XCTAssertEqual(state.shift(code: 60, down: false, at: 2), .stop)
        XCTAssertNil(state.shift(code: 60, down: false, at: 2.1))
    }

    func testTypingCombinationsAndSimultaneousShiftDoNotToggle() {
        var state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 1))
        XCTAssertNil(state.shift(code: 56, down: true, at: 1.2))
        XCTAssertNil(state.combination())
        XCTAssertNil(state.shift(code: 56, down: false, at: 1.3))
        XCTAssertNil(tap(&state, at: 1.4))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 2))
        XCTAssertNil(state.shift(code: 60, down: true, at: 2.01))
        XCTAssertNil(state.shift(code: 56, down: false, at: 2.1))
        XCTAssertNil(state.shift(code: 60, down: false, at: 2.2))
        XCTAssertNil(tap(&state, at: 2.3))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 3, modified: true))
        XCTAssertNil(state.shift(code: 56, down: false, at: 3.1))
        XCTAssertNil(tap(&state, at: 3.2))
        XCTAssertFalse(state.recording)
        var press = DictationShortcutState(mode: .press, key: .right)
        XCTAssertNil(press.shift(code: 60, down: true, at: 1))
        XCTAssertNil(press.combination())
        XCTAssertNil(press.shift(code: 60, down: false, at: 1.1))
    }

    func testHoldTypingCancelsAndResetDiscardsPendingTap() {
        var state = DictationShortcutState(mode: .hold)
        XCTAssertNil(state.shift(code: 56, down: true, at: 1))
        XCTAssertNil(state.combination())
        XCTAssertNil(state.holdElapsed(at: 1.3))
        state.reset()
        XCTAssertNil(state.shift(code: 56, down: true, at: 2))
        XCTAssertEqual(state.holdElapsed(at: 2.3), .start)
        XCTAssertEqual(state.combination(), .cancel)
        XCTAssertNil(state.shift(code: 56, down: false, at: 2.4))
        state = DictationShortcutState()
        XCTAssertNil(tap(&state, at: 3))
        state.reset()
        XCTAssertNil(tap(&state, at: 3.2))
    }

    func testMicrophoneFallbackRetainsPreferenceAndReconnects() {
        let headphones = DictationMicrophone(id: "headset", deviceID: 1, name: "Headset", builtIn: false)
        let builtIn = DictationMicrophone(id: "mac", deviceID: 2, name: "MacBook Microphone", builtIn: true)
        let preference = "headset"
        XCTAssertEqual(DictationMicrophone.resolve(preference: "", devices: [headphones, builtIn], defaultDevice: 2), builtIn)
        XCTAssertEqual(DictationMicrophone.resolve(preference: preference, devices: [builtIn]), builtIn)
        XCTAssertEqual(preference, "headset")
        XCTAssertEqual(DictationMicrophone.resolve(preference: preference, devices: [headphones, builtIn], defaultDevice: 2), headphones)
        XCTAssertNil(DictationMicrophone.resolve(preference: preference, devices: []))
    }

    @MainActor
    func testCapsuleUsesDictationCompletionAndFailureLabels() async throws {
        _ = NSApplication.shared
        let model = DictationCapsuleModel()
        XCTAssertEqual(model.phase.title, "Ready")
        model.phase = .transcribing
        XCTAssertEqual(model.phase.title, "Transcribing…")
        model.phase = .copied
        XCTAssertEqual(model.phase.title, "Copied to clipboard")
        model.phase = .failed("Microphone disconnected")
        XCTAssertEqual(model.phase.title, "Microphone disconnected")
        let capsule = DictationCapsuleWindowController(model: model)
        XCTAssertFalse(capsule.window!.canBecomeKey)
        XCTAssertFalse(capsule.window!.canBecomeMain)
        model.recoveryText = "Recovered text"
        capsule.present()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(capsule.window!.frame.height, 244, accuracy: 1)
        capsule.dismiss()

    }

    func testPermissionSetupAdvancesOnlyWhenAccessIsGranted() {
        var permissions = DictationPermissions(accessibility: false, keyboard: false, microphone: false)
        XCTAssertEqual(permissions.next, .accessibility)
        XCTAssertFalse(permissions.isReady)
        XCTAssertFalse(permissions.canRecord)
        permissions.accessibility = true
        XCTAssertEqual(permissions.next, .keyboard)
        permissions.keyboard = true
        XCTAssertEqual(permissions.next, .microphone)
        XCTAssertFalse(permissions.isReady)
        permissions.microphone = true
        XCTAssertTrue(permissions.isReady)
        XCTAssertNil(permissions.next)
        permissions.accessibility = false
        XCTAssertFalse(permissions.isReady)
        XCTAssertTrue(permissions.canRecord)
        XCTAssertEqual(permissions.next, .accessibility)
    }

    func testPermissionDragProvidesAppFileURL() {
        let url = URL(fileURLWithPath: "/Applications/Aegis.app", isDirectory: true)
        let provider = NSItemProvider(object: url as NSURL)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(DictationPermission.accessibility.settingsURL.fragment, nil)
        XCTAssertEqual(DictationPermission.accessibility.settingsURL.query, "Privacy_Accessibility")
    }

    func testRunningRecorderIgnoresUnchangedConfigurationNotification() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let sameFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertFalse(DictationAudioRecorder.configurationRequiresStop(
            isRunning: true, originalFormat: format, currentFormat: sameFormat))
    }

    func testRecorderStopsForStoppedEngineOrChangedInputFormat() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertTrue(DictationAudioRecorder.configurationRequiresStop(
            isRunning: false, originalFormat: format, currentFormat: format))
        let changed = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        XCTAssertTrue(DictationAudioRecorder.configurationRequiresStop(
            isRunning: true, originalFormat: format, currentFormat: changed))
    }

    func testShortcutSurvivesApplicationChangesAndRangesUseUTF16() throws {
        var shortcut = DictationShortcutState()
        XCTAssertNil(tap(&shortcut, at: 1))
        XCTAssertEqual(tap(&shortcut, at: 1.2), .start)
        shortcut.applicationChanged()
        XCTAssertTrue(shortcut.recording)
        XCTAssertNil(tap(&shortcut, at: 2))
        XCTAssertEqual(tap(&shortcut, at: 2.2), .stop)

        XCTAssertEqual(DictationInsertion.replacing(NSRange(location: 9, length: 5), in: "Hello 🌍 world", with: "Aegis"), "Hello 🌍 Aegis")
    }

    @MainActor
    func testUnavailableDestinationPreservesTextInsteadOfOverwritingEdits() throws {
        XCTAssertNil(DictationInsertion.replacing(NSRange(location: Int.max, length: 1), in: "Original", with: "words"))
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try DictationInsertion.copy("First transcript", to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "First transcript")
        try DictationInsertion.copy("Second transcript", to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), "Second transcript")
    }

    @MainActor
    func testEmptyRecordingFailsBeforeTranscription() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do { _ = try AVAudioFile(forWriting: audio, settings: format.settings) }
        do {
            _ = try await DictationTranscriptionRunner().transcribe(audioFile: audio, language: "auto")
            XCTFail("Empty audio was accepted")
        } catch DictationTranscriptionError.recordingEmpty {}
    }

    func testMeterThrottlingKeepsUpdatesBelowThirtyPerSecond() {
        var gate = DictationSpeechGate()
        gate.append(rms: 0.0001, frames: 48_000, sampleRate: 48_000)
        XCTAssertFalse(gate.hasSpeech)
        gate.append(rms: 0.02, frames: 6_000, sampleRate: 48_000)
        XCTAssertTrue(gate.hasSpeech)
        var throttle = VoiceLevelThrottle()
        var updates = 0
        for _ in 0..<46 {
            if throttle.shouldPublish(frames: 1024, sampleRate: 48_000) { updates += 1 }
        }
        XCTAssertEqual(updates, 23)
        XCTAssertFalse(throttle.shouldPublish(frames: 0, sampleRate: 48_000))
    }

    @MainActor
    func testPasteVerificationWaitsForDelayedEditorUpdate() async throws {
        var reads = 0
        let verified = try await DictationInsertion.verifyPaste(before: "Original", expected: "Original words") {
            reads += 1
            return reads < 3 ? "Original" : "Original words"
        }
        XCTAssertTrue(verified)
        XCTAssertEqual(reads, 3)
    }

    @MainActor
    func testPasteVerificationRejectsUnexpectedEditsWithoutRetrying() async throws {
        var reads = 0
        let verified = try await DictationInsertion.verifyPaste(before: "Original", expected: "Original words") {
            reads += 1
            return "User edit"
        }
        XCTAssertFalse(verified)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testMissingReadbackDoesNotClaimInsertion() async throws {
        let verified = try await DictationInsertion.verifyPaste(before: nil, expected: nil) { nil }
        XCTAssertFalse(verified)
        XCTAssertNil(DictationInsertion.replacing(nil, in: "Original", with: "words"))
    }

    @MainActor
    func testRecordingMuteRestoresOnlyPreviouslyAudibleOutputs() throws {
        var muted: [UInt32: Bool] = [1: false, 2: true]
        let output = DictationOutputMute(devices: { [1, 2, 1] },
            readMute: { muted[$0]! }, writeMute: { muted[$0] = $1 })
        try output.mute()
        XCTAssertEqual(muted, [1: true, 2: true])
        try output.mute()
        output.restore()
        output.restore()
        XCTAssertEqual(muted, [1: false, 2: true])
    }

    @MainActor
    func testRecordingMuteRollsBackIfAnOutputCannotBeMuted() {
        var muted: [UInt32: Bool] = [1: false, 2: false]
        var writes = 0
        let output = DictationOutputMute(devices: { [1, 2] }, readMute: { muted[$0]! }, writeMute: { device, value in
            if value {
                writes += 1
                if writes == 2 { throw DictationFailure(message: "Output unavailable") }
            }
            muted[device] = value
        })
        XCTAssertThrowsError(try output.mute())
        XCTAssertEqual(muted, [1: false, 2: false])
        var failRestore = true
        let unavailable = DictationOutputMute(devices: { [1] }, readMute: { muted[$0]! }, writeMute: { device, value in
            if !value && failRestore { throw DictationFailure(message: "Output disconnected") }
            muted[device] = value
        })
        try? unavailable.mute()
        XCTAssertFalse(unavailable.restore())
        failRestore = false
        XCTAssertTrue(unavailable.restore())
        XCTAssertEqual(muted[1], false)
    }

    @MainActor
    func testDictationCommandsCorrectionsAndAggregatePersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-data-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DictationData(directory: directory)
        let corrections = CorrectionLearner.corrections(from: "Open Agis now", to: "Open Aegis now")
        XCTAssertEqual(corrections, [LearnedCorrection(heard: "Agis", corrected: "Aegis")])
        data.learn(corrections)
        XCTAssertEqual(DictationData.replace("Open Agis now", using: data.vocabulary), "Open Aegis now")
        XCTAssertEqual(VoiceCommands.apply("Hello comma how are you question mark"), "Hello, how are you?")
        XCTAssertEqual(VoiceCommands.apply("Save 20 percent today"), "Save 20% today")
        XCTAssertEqual(VoiceCommands.apply("New paragraph."), "\n\n")
        XCTAssertTrue(DictationController.usesEnglishCommands("Hello comma how are you", language: "auto"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        data.record(words: 10, seconds: 5, date: date)
        data.record(words: 20, seconds: 10, date: date)
        let restored = DictationData(directory: directory)
        XCTAssertEqual(restored.vocabulary, data.vocabulary)
        XCTAssertEqual(restored.days.count, 1)
        XCTAssertEqual(restored.days[0].words, 30)
        XCTAssertEqual(restored.days[0].sessions, 2)
        let saved = try String(contentsOf: directory.appendingPathComponent("insights.json"))
        XCTAssertFalse(saved.contains("Agis"))
        XCTAssertFalse(saved.contains("transcript"))
        restored.resetInsights()
        XCTAssertTrue(restored.days.isEmpty)
        XCTAssertEqual(restored.vocabulary.count, 1)
    }

    @MainActor
    func testDictationRejectsUnsafeLearningAndPreservesUnreadableData() throws {
        XCTAssertFalse(DictationController.usesEnglishCommands("Bonjour comma comment allez-vous", language: "fr"))
        XCTAssertFalse(DictationController.usesEnglishCommands("Bonjour comma comment allez-vous", language: "auto"))
        XCTAssertEqual(VoiceCommands.apply("the Oxford comma"), "the Oxford comma")
        XCTAssertTrue(CorrectionLearner.corrections(from: "I like that", to: "I love that").isEmpty)
        XCTAssertTrue(CorrectionLearner.corrections(from: String(repeating: "word ", count: 257), to: "changed").isEmpty)
        let longWord = String(repeating: "a", count: 121)
        XCTAssertTrue(CorrectionLearner.corrections(from: longWord, to: longWord + "b").isEmpty)
        let entries = [DictationWord(heard: "café", replacement: "Aegis"), DictationWord(heard: "Aegis", replacement: "other")]
        XCTAssertEqual(DictationData.replace("café cafés", using: entries), "Aegis cafés")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("vocabulary.json")
        try Data("unreadable".utf8).write(to: file)
        let data = DictationData(directory: directory)
        XCTAssertNotNil(data.error)
        XCTAssertThrowsError(try data.saveWord(heard: "Agis", replacement: "Aegis"))
        XCTAssertEqual(try String(contentsOf: file), "unreadable")
        XCTAssertThrowsError(try DictationTranscriptionRunner.validateModel(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Encoder.mlmodelc").path))
    }

}
