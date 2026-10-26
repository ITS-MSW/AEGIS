import AVFoundation
import Combine
import FluidAudio

@MainActor
final class DictationTranscriptionRunner: ObservableObject {
    static let shared = DictationTranscriptionRunner()
    @Published private(set) var status = ""
    @Published private(set) var preparing = false
    private var manager: AsrManager?
    var isReady: Bool { manager != nil }
    private var preparation: Task<AsrManager, Error>?
    @Published private(set) var transcribing = false

    nonisolated static let languages = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
    nonisolated static let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Aegis/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
    nonisolated static let existingModelDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/BetterWispr/Models/Parakeet/parakeet-tdt-0.6b-v3", isDirectory: true)

    func prepare(importing source: URL? = nil) async throws {
        if manager != nil { return }
        if let preparation {
            do { manager = try await preparation.value }
            catch { throw DictationTranscriptionError.modelMissing }
            return
        }
        preparing = true
        status = "Preparing model…"
        let task = Task.detached {
            if let source { try Self.importFiles(from: source, to: Self.modelDirectory) }
            else if !FileManager.default.fileExists(atPath: Self.modelDirectory.path) {
                try Self.importFiles(from: Self.existingModelDirectory, to: Self.modelDirectory)
            }
            try Self.validateModel(at: Self.modelDirectory)
            let models = try AsrModels.loadLocal(from: Self.modelDirectory, version: .v3)
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        preparation = task
        defer { preparation = nil; preparing = false }
        do {
            manager = try await task.value
            status = ""
        } catch {
            status = "Import the Parakeet TDT v3 model to enable dictation."
            throw DictationFailure(message: status)
        }
    }

    func importModel(from source: URL) async {
        guard !preparing, !transcribing else { return }
        manager = nil
        do { try await prepare(importing: source) }
        catch { status = "Could not import this model. Choose the Parakeet TDT v3 folder." }
    }

    func transcribe(audioFile: URL, language: String) async throws -> String {
        try Task.checkCancellation()
        let audio = try AVAudioFile(forReading: audioFile)
        guard audio.length > 0 else { throw DictationTranscriptionError.recordingEmpty }
        guard !transcribing else { throw DictationFailure(message: "Wait for the current dictation to finish.") }
        transcribing = true
        defer { transcribing = false }
        try await prepare()
        try Task.checkCancellation()
        guard let manager else { throw DictationTranscriptionError.modelMissing }
        var decoder = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let hint = Self.languages.contains(language) ? Language(rawValue: language) : nil
        let result: ASRResult
        do { result = try await manager.transcribe(audioFile, decoderState: &decoder, language: hint) }
        catch is CancellationError { throw CancellationError() }
        catch { throw DictationFailure(message: "Could not transcribe. Try again or reimport the model.") }
        try Task.checkCancellation()
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DictationTranscriptionError.noSpeech }
        return text
    }

    nonisolated static func validateModel(at directory: URL) throws {
        let files = ["Encoder.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"]
        for name in files {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue == name.hasSuffix(".mlmodelc") else { throw DictationTranscriptionError.modelMissing }
            if isDirectory.boolValue {
                guard !(try FileManager.default.contentsOfDirectory(atPath: url.path)).isEmpty else {
                    throw DictationTranscriptionError.modelMissing
                }
            }
        }
        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard let vocabulary = try JSONSerialization.jsonObject(with: data) as? [String: String],
              !vocabulary.isEmpty else { throw DictationTranscriptionError.modelMissing }
    }

    nonisolated static func importFiles(from source: URL, to destination: URL) throws {
        try validateModel(at: source)
        if source.standardizedFileURL == destination.standardizedFileURL { return }
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try validateModel(at: staging)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }
}

enum DictationTranscriptionError: LocalizedError {
    case modelMissing, microphoneDenied, microphoneUnavailable, recordingEmpty, recordingFailed, noSpeech
    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Import Parakeet TDT v3 in Transcription settings."
        case .microphoneDenied: return "Allow microphone access in System Settings."
        case .microphoneUnavailable: return "Connect a microphone and try again."
        case .recordingEmpty: return "No audio received. Check your microphone."
        case .recordingFailed: return "Recording stopped. Check your microphone and try again."
        case .noSpeech: return "No speech detected. Try again."
        }
    }
}
