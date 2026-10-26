import AppKit
import AVFoundation
import Combine

@MainActor
final class DictationController {
    private let preparationLimit: Duration
    private let requestMicrophone: () async -> Bool
    private let settings: SettingsStore
    private let shortcut = GlobalDictationShortcut()
    private var audio = DictationAudio()
    private let outputMute = DictationOutputMute()
    private let runner = DictationTranscriptionRunner.shared
    private let model = DictationCapsuleModel()
    private lazy var capsule = DictationCapsuleWindowController(model: model)
    private var subscriptions = Set<AnyCancellable>()
    private(set) var operation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var generation = UUID()
    private var destinationTask: Task<DictationInsertion?, Error>?
    private let corrections = DictationCorrections()
    private var activeDevice: String?
    private var startedAt: Date?
    private(set) var requesting = false
    private var enabled = false

    init(settings: SettingsStore, preparationLimit: Duration = .seconds(10),
         requestMicrophone: @escaping () async -> Bool = DictationMicrophonePermission.request) {
        self.preparationLimit = preparationLimit
        self.requestMicrophone = requestMicrophone
        self.settings = settings
    }

    func start() {
        _ = capsule
        model.onCancel = { [weak self] in self?.cancel() }
        model.onFinish = { [weak self] in self?.handle(.stop) }
        model.onCopy = { [weak self] in
            guard let self, let text = model.recoveryText else { return }
            do {
                try DictationInsertion.copy(text)
                model.recoveryText = nil
                model.phase = .copied
                capsule.present()
                dismiss(after: 1.8)
            } catch { fail(error) }
        }
        let launchedAt = Date()
        Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-dictation")
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
                if file.lastPathComponent.hasPrefix("utterance-"),
                   let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate, created < launchedAt {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        shortcut.onAction = { [weak self] in self?.handle($0) }
        shortcut.onFailure = { [weak self] in
            self?.fail(DictationFailure(message: "Keyboard monitoring was interrupted. Try the shortcut again."))
        }
        settings.$dictationEnabled.combineLatest(settings.$dictationMode, settings.$dictationShiftKey)
            .sink { [weak self] enabled, mode, key in
                guard let self else { return }
                cancel()
                shortcut.stop()
                self.enabled = enabled
                shortcut.state = DictationShortcutState(mode: mode, key: key)
                model.held = mode == .hold
                registerShortcut()
                if enabled {
                    Task { try? await self.runner.prepare() }
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .dictationPermissionsChanged)
            .sink { [weak self] _ in self?.registerShortcut() }.store(in: &subscriptions)
        DictationMicrophoneMonitor.shared.$devices.dropFirst().sink { [weak self] devices in
            guard let self, let activeDevice, !devices.contains(where: { $0.id == activeDevice }) else { return }
            cancel()
            fail(DictationFailure(message: "The recording microphone disconnected. Reconnect it or try again with the fallback microphone."))
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                self?.shortcut.applicationChanged()
            }.store(in: &subscriptions)
        settings.$dictationMuteWhileRecording.dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled { restoreOutputSound() }
                else if startedAt != nil {
                    do { try outputMute.mute() }
                    catch { cancel(); fail(error) }
                }
            }.store(in: &subscriptions)
        settings.$dictationLearnCorrections.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.corrections.stop() }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.cancel() }.store(in: &subscriptions)
    }

    private func registerShortcut() {
        guard enabled else { settings.dictationStatus = ""; return }
        let permissions = DictationPermissions.current()
        guard permissions.canRecord else {
            shortcut.stop()
            settings.dictationStatus = "Finish setting up dictation access to start."
            return
        }
        if shortcut.start() {
            settings.dictationStatus = permissions.accessibility ? "" : "Text will be copied. Allow Accessibility to paste."
        } else {
            settings.dictationStatus = "Keyboard access has changed. Quit and reopen Aegis to apply it."
        }
    }

    func stop() {
        enabled = false
        shortcut.stop()
        cancel()
        subscriptions.removeAll()
    }

    func handle(_ action: DictationShortcutState.Action) {
        switch action {
        case .start:
            guard operation == nil, startedAt == nil, !requesting else { shortcut.reset(); return }
            begin()
        case .stop:
            if requesting { cancel() }
            else if startedAt != nil { finish() }
        case .cancel: cancel()
        }
    }

    private func begin() {
        guard enabled else { return }
        if model.recoveryText != nil { capsule.present(); shortcut.reset(); return }
        dismissal?.cancel()
        corrections.stop()
        model.recoveryText = nil
        guard runner.isReady || runner.preparing else { fail(DictationTranscriptionError.modelMissing); return }
        model.phase = .preparing
        model.levels = Array(repeating: 0, count: 13)
        capsule.present()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        destinationTask = Task.detached { try pid.flatMap { try DictationInsertion.capture(pid: $0) } }
        prepareMicrophone()
    }

    func prepareMicrophone() {
        let audio = DictationAudio()
        self.audio = audio
        generation = UUID()
        let token = generation
        requesting = true
        model.phase = .preparing
        model.levels = Array(repeating: 0, count: 13)
        settings.dictationStatus = "Preparing microphone…"
        timeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: preparationLimit)
            guard !Task.isCancelled, token == generation, requesting else { return }
            Log.error("Dictation preparation timed out")
            cancel()
            fail(DictationFailure(message: "Microphone preparation took too long. Try dictating again."))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                Log.info("Dictation preparation stage=permission")
                let granted = await requestMicrophone()
                guard token == generation, !Task.isCancelled else { return }
                guard granted else { throw DictationTranscriptionError.microphoneDenied }
                _ = try await destinationTask?.value
                guard token == generation, !Task.isCancelled else { return }
                let preference = settings.dictationMicrophoneID
                Log.info("Dictation preparation stage=devices")
                let devices = await Task.detached { DictationMicrophone.available() }.value
                guard token == generation, !Task.isCancelled else { return }
                guard let device = DictationMicrophone.resolve(preference: preference, devices: devices) else {
                    throw DictationTranscriptionError.microphoneUnavailable
                }
                activeDevice = device.id
                if settings.dictationMuteWhileRecording {
                    Log.info("Dictation preparation stage=mute-output")
                    try outputMute.mute()
                }
                Log.info("Dictation preparation stage=audio-start")
                try await audio.start(device: device.deviceID, level: { [weak self] level in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.model.appendLevel(level)
                    }
                }, failure: { [weak self] in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.cancel()
                        self.fail(DictationTranscriptionError.recordingFailed)
                    }
                })
                guard token == generation, !Task.isCancelled else { return }
                Log.info("Dictation preparation stage=recording")
                timeout?.cancel()
                requesting = false
                operation = nil
                startedAt = Date()
                model.phase = .recording
                capsule.present()
                settings.dictationStatus = DictationMicrophoneMonitor.shared.status(preference: preference)
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled else { return }
                    self?.finish()
                }
            } catch {
                guard token == generation else { return }
                cancel()
                fail(error)
            }
        }
    }

    private func finish() {
        guard let startedAt else { return }
        self.startedAt = nil
        activeDevice = nil
        timeout?.cancel()
        shortcut.reset()
        let duration = Date().timeIntervalSince(startedAt)
        let token = generation
        let destinationTask = destinationTask
        let audio = audio
        let language = settings.dictationLanguage
        let commands = settings.dictationVoiceCommands
        let entries = DictationData.shared.vocabulary
        model.phase = .transcribing
        capsule.present()
        settings.dictationStatus = "Transcribing…"
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            guard let self, token == generation, operation != nil else { return }
            cancel()
            fail(DictationFailure(message: "Transcription stalled. Restart Aegis to try again."))
        }
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let recordedFile = try await audio.stop()
                restoreOutputSound()
                try Task.checkCancellation()
                guard let file = recordedFile, duration >= 0.25 else { throw DictationTranscriptionError.noSpeech }
                let raw = try await runner.transcribe(audioFile: file, language: language)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                let commandEntries = entries.filter { VoiceCommands.isSpokenCommand($0.replacement) }
                let text = DictationData.replace(raw, using: commandEntries)
                let spoken = commands && Self.usesEnglishCommands(text, language: language) ? VoiceCommands.apply(text) : text
                let transcript = DictationData.replace(spoken, using: entries.filter { !VoiceCommands.isSpokenCommand($0.replacement) })
                    .trimmingCharacters(in: .whitespaces)
                guard !transcript.isEmpty else {
                    capsule.dismiss()
                    model.phase = .idle
                    settings.dictationStatus = ""
                    await audio.removeRecording()
                    if token == generation { operation = nil; timeout?.cancel() }
                    return
                }
                let target = try await destinationTask?.value
                try Task.checkCancellation()
                model.recoveryText = transcript
                let inserted: NSRange?
                if let target { inserted = try await target.insert(transcript) }
                else { try DictationInsertion.copy(transcript); inserted = nil }
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                model.recoveryText = nil
                DictationData.shared.record(words: transcript.split(whereSeparator: \.isWhitespace).count, seconds: duration)
                if let inserted, let target {
                    capsule.dismiss()
                    model.phase = .idle
                    settings.dictationStatus = ""
                    if settings.dictationLearnCorrections {
                        corrections.watch(transcript, range: inserted, destination: target) { DictationData.shared.learn($0) }
                    }
                } else {
                    model.phase = .copied
                    settings.dictationStatus = ""
                    capsule.present()
                    dismiss(after: 1.8)
                }
            } catch {
                if token == generation && !Task.isCancelled { fail(error) }
            }
            await audio.removeRecording()
            if token == generation { operation = nil; timeout?.cancel() }
        }
    }

    static func usesEnglishCommands(_ text: String, language: String) -> Bool {
        if language == "en" { return true }
        guard language == "auto" else { return false }
        if VoiceCommands.isSpokenCommand(text) { return true }
        let words = CorrectionLearner.tokenize(text).map { $0.lowercased() }
        let english = words.filter { CorrectionLearner.commonWords.contains($0) || ["hello", "please", "thanks"].contains($0) }.count
        // shortcut: ambiguous automatic-language text stays literal; select English for reliable commands.
        return english >= 2 && Double(english) / Double(max(1, words.count)) >= 0.3
    }

    private func restoreOutputSound() {
        settings.dictationAudioStatus = outputMute.restore() ? "" : "Could not restore sound. Unmute your output in macOS Sound settings."
    }

    private func cancel() {
        restoreOutputSound()
        generation = UUID()
        operation?.cancel()
        // Transcription cleanup stays serialized; preparation uses a recorder owned by that attempt.
        let previous = operation
        let audio = audio
        let token = generation
        if requesting {
            // A stalled preparation must not hold the next attempt; its recorder is never reused.
            operation = nil
            self.audio = DictationAudio()
            Task { await audio.cancel() }
        } else {
            operation = Task { [weak self] in
                guard let self else { return }
                await previous?.value
                await audio.cancel()
                if token == generation { operation = nil }
            }
        }
        timeout?.cancel()
        dismissal?.cancel()
        settings.dictationStatus = ""
        requesting = false
        startedAt = nil
        activeDevice = nil
        destinationTask?.cancel()
        destinationTask = nil
        corrections.stop()
        model.recoveryText = nil
        shortcut.reset()
        capsule.dismiss()
    }

    private func fail(_ error: Error) {
        restoreOutputSound()
        shortcut.reset()
        activeDevice = nil
        model.phase = .failed(error.localizedDescription)
        settings.dictationStatus = error.localizedDescription
        capsule.present()
    }

    private func dismiss(after seconds: Double) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.capsule.dismiss()
        }
    }
}

enum DictationMicrophonePermission {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
