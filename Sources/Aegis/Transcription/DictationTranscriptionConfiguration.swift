import Foundation

struct HermesInstallation: Equatable {
    let rootDirectory: URL
    let pythonExecutable: URL
}

enum DictationTranscriptionConfiguration {
    static func installation(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) -> HermesInstallation? {
        let roots = [
            homeDirectory.appendingPathComponent(".hermes/hermes-agent", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/share/hermes/hermes-agent", isDirectory: true),
        ]

        for root in roots {
            let candidates = [
                root.appendingPathComponent("venv/bin/python"),
                root.appendingPathComponent(".venv/bin/python"),
            ]
            if let python = candidates.first(where: fileExists) {
                return HermesInstallation(rootDirectory: root, pythonExecutable: python)
            }
        }
        return nil
    }
}

enum DictationTranscriptionError: LocalizedError {
    case installationMissing
    case microphoneDenied
    case microphoneUnavailable
    case recordingEmpty
    case recordingFailed
    case noSpeech
    case transcriptionFailed(String?)

    var errorDescription: String? {
        switch self {
        case .installationMissing:
            return "Hermes is not ready on this Mac."
        case .microphoneDenied:
            return "Allow microphone access in System Settings."
        case .microphoneUnavailable:
            return "No microphone is available."
        case .recordingEmpty:
            return "No audio reached Aegis. Check the selected microphone and try again."
        case .recordingFailed:
            return "The recording could not be completed."
        case .noSpeech:
            return "No speech was detected."
        case .transcriptionFailed(let detail):
            return detail?.isEmpty == false ? detail : "Hermes could not transcribe the recording."
        }
    }
}

struct DictationTranscriptionProcessPlan: Equatable {
    let executable: URL
    let arguments: [String]
    let currentDirectory: URL
}

enum DictationTranscriptionProcessPlanner {
    static let transcriptionScript = """
import json
import sys
import time

import_started = time.perf_counter()
from tools.voice_mode import transcribe_recording
import_ms = (time.perf_counter() - import_started) * 1000

transcription_started = time.perf_counter()
result = transcribe_recording(sys.argv[1])
transcription_ms = (time.perf_counter() - transcription_started) * 1000
print(json.dumps({
    "importMilliseconds": import_ms,
    "transcriptionMilliseconds": transcription_ms,
    "success": bool(result.get("success")),
    "transcript": (result.get("transcript") or "").strip(),
    "error": str(result.get("error") or "")
}))
"""

    static func transcriptionPlan(
        installation: HermesInstallation,
        audioFile: URL
    ) -> DictationTranscriptionProcessPlan {
        DictationTranscriptionProcessPlan(
            executable: installation.pythonExecutable,
            arguments: ["-c", transcriptionScript, audioFile.path],
            currentDirectory: installation.rootDirectory
        )
    }
}
