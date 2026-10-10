import Foundation
import AVFoundation
import Darwin

private struct HermesTranscriptionPayload: Decodable {
    let success: Bool
    let transcript: String
    let error: String
    let importMilliseconds: Double?
    let transcriptionMilliseconds: Double?
}

actor DictationTranscriptionRunner {
    private var transcriptions: [UUID: Process] = [:]

    func transcribe(audioFile: URL, installation: HermesInstallation) async throws -> String {
        let recording = try AVAudioFile(forReading: audioFile)
        guard recording.length > 0 else {
            throw DictationTranscriptionError.recordingEmpty
        }
        let plan = DictationTranscriptionProcessPlanner.transcriptionPlan(
            installation: installation,
            audioFile: audioFile
        )
        let started = ProcessInfo.processInfo.systemUptime
        let output = try await runToCompletion(plan)
        let totalMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        guard let payload = transcriptionPayload(from: output),
              payload.success else {
            let detail = transcriptionPayload(from: output)?.error
            throw DictationTranscriptionError.transcriptionFailed(detail)
        }
        if let imports = payload.importMilliseconds, let transcription = payload.transcriptionMilliseconds {
            Log.info(String(format: "Dictation timing total_ms=%.1f import_ms=%.1f transcription_ms=%.1f process_and_io_ms=%.1f",
                totalMilliseconds, imports, transcription, max(0, totalMilliseconds - imports - transcription)))
        }
        let transcript = payload.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw DictationTranscriptionError.noSpeech }
        return transcript
    }

    func stop() {
        for identifier in transcriptions.keys { cancelTranscription(identifier) }
    }

    private func transcriptionPayload(from data: Data) -> HermesTranscriptionPayload? {
        if let direct = try? JSONDecoder().decode(HermesTranscriptionPayload.self, from: data) {
            return direct
        }
        for line in data.split(separator: 0x0A).reversed() {
            if let payload = try? JSONDecoder().decode(HermesTranscriptionPayload.self, from: Data(line)) {
                return payload
            }
        }
        return nil
    }

    private func cancelTranscription(_ identifier: UUID) {
        guard let process = transcriptions[identifier], process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func runToCompletion(_ plan: DictationTranscriptionProcessPlan) async throws -> Data {
        try Task.checkCancellation()
        let identifier = UUID()
        let process = Process()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aegis-transcription-\(identifier).log")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: url)
        defer {
            transcriptions[identifier] = nil
            try? output.close()
            try? FileManager.default.removeItem(at: url)
        }
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.currentDirectory
        process.environment = Self.hermesEnvironment
        process.standardOutput = output
        process.standardError = output
        transcriptions[identifier] = process
        let deadline = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            cancelTranscription(identifier)
        }
        defer { deadline.cancel() }
        // A file avoids blocking the child on a full stdout pipe before termination.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: DictationTranscriptionError.transcriptionFailed(nil))
                    }
                }
                do { try process.run() }
                catch { continuation.resume(throwing: DictationTranscriptionError.installationMissing) }
            }
        } onCancel: {
            Task { await self.cancelTranscription(identifier) }
        }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }

    private static var hermesEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Match the official Hermes launcher. Python path injection can make
        // the managed venv import modules from an unrelated active project.
        environment["PYTHONPATH"] = nil
        environment["PYTHONHOME"] = nil
        return environment
    }
}
