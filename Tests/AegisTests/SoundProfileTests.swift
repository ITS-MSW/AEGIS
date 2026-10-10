import AVFoundation
import XCTest
@testable import Aegis

final class SoundProfileTests: XCTestCase {
    func testProfessionalProfilesHaveStableNames() {
        XCTAssertEqual(
            SoundProfile.allCases.map(\.displayName),
            ["Quiet Glass", "Soft Relay", "Deep Signal", "Meme", "F1"]
        )
    }

    func testMemeProfileHasReadableVoiceCues() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/sounds/meme", isDirectory: true)

        for name in ["yamete-kudasai"] {
            let file = try AVAudioFile(
                forReading: resources.appendingPathComponent("\(name).aiff")
            )
            XCTAssertGreaterThan(file.length, 0, name)
            XCTAssertEqual(file.processingFormat.channelCount, 1, name)
        }
    }

    func testMemeProfileUsesEventSpecificClips() {
        let profile = SoundProfile.meme

        for event in SoundEvent.allCases {
            XCTAssertEqual(profile.bundledSoundName(for: event), "yamete-kudasai", event.rawValue)
        }
    }

    func testF1ProfileUsesReadableEventClips() throws {
        let profile = SoundProfile.f1
        XCTAssertEqual(SettingsStore.resolveSoundProfile(rawValue: "f1"), profile)
        XCTAssertEqual(profile.previewEvents, [.sessionEnd, .error])
        XCTAssertEqual(profile.bundledSoundSubdirectory, "sounds/f1")
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/\(try XCTUnwrap(profile.bundledSoundSubdirectory))")
        let clips: [SoundEvent: String] = [
            .sessionEnd: "completion",
            .error: "failure",
        ]

        for event in SoundEvent.allCases {
            XCTAssertEqual(profile.bundledSoundName(for: event), clips[event], event.rawValue)
        }
        for name in Set(clips.values) {
            let file = try AVAudioFile(forReading: resources.appendingPathComponent("\(name).aiff"))
            XCTAssertGreaterThan(file.length, 0, name)
            XCTAssertEqual(file.processingFormat.channelCount, 1, name)
            XCTAssertEqual(file.processingFormat.sampleRate, 44_100, name)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            XCTAssertGreaterThan(peakAmplitude(of: buffer), 0.01, name)
        }
    }

    func testOnlySessionEndAndErrorTriggerSounds() {
        XCTAssertEqual(SoundEvent.allCases, [.sessionEnd, .error])
        XCTAssertEqual(SoundEvent(sessionEvent: .sessionEnded("session")), .sessionEnd)
        XCTAssertEqual(SoundEvent(sessionEvent: .statusChanged("session", .error)), .error)

        let silentEvents: [SessionEvent] = [
            .sessionStarted("session"),
            .statusChanged("session", .idle),
            .statusChanged("session", .thinking),
            .toolStarted("session", "Bash"),
            .toolEnded("session", "Bash", .success),
            .permissionRequested("session"),
            .permissionResponded("session", true),
            .permissionResponded("session", false),
            .questionAsked("session"),
            .pendingDismissedExternally("session"),
            .notification("session", "message"),
        ]
        for event in silentEvents {
            XCTAssertNil(SoundEvent(sessionEvent: event))
        }
    }

    func testEveryProfileGeneratesTwoDistinctBoundedCues() throws {
        for profile in SoundProfile.allCases {
            XCTAssertEqual(profile.previewEvents, [.sessionEnd, .error])
            let synthesizer = SoundSynthesizer(profile: profile)
            let buffers = try SoundEvent.allCases.map {
                try XCTUnwrap(synthesizer.generateSound(for: $0))
            }

            XCTAssertEqual(Set(buffers.map(\.frameLength)).count, 2, profile.displayName)
            for buffer in buffers {
                XCTAssertGreaterThan(buffer.frameLength, 0)
                XCTAssertLessThanOrEqual(peakAmplitude(of: buffer), 0.24)
                XCTAssertGreaterThan(peakAmplitude(of: buffer), 0.01)
                XCTAssertEqual(try firstSample(in: buffer), 0, accuracy: 0.000_001)
                XCTAssertEqual(try lastSample(in: buffer), 0, accuracy: 0.001)
            }
        }
    }

    func testProfilesProduceDifferentCompletionContours() throws {
        let synthesizedProfiles = SoundProfile.allCases.filter { $0.bundledSoundSubdirectory == nil }
        let signatures = try synthesizedProfiles.map { profile in
            let buffer = try XCTUnwrap(
                SoundSynthesizer(profile: profile).generateSound(for: .sessionEnd)
            )
            return Int(meanAbsoluteAmplitude(of: buffer) * 1_000_000)
        }

        XCTAssertEqual(Set(signatures).count, synthesizedProfiles.count)
    }

    func testLegacyYameteProfileMigratesToMeme() {
        XCTAssertEqual(SettingsStore.resolveSoundProfile(rawValue: "yamete-kudasai"), .meme)
        XCTAssertEqual(SettingsStore.resolveSoundProfile(rawValue: "meme"), .meme)
        XCTAssertEqual(SettingsStore.resolveSoundProfile(rawValue: "unknown"), .quietGlass)
    }

    private func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(0) { peak, frame in
            max(peak, abs(samples[frame]))
        }
    }

    private func meanAbsoluteAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let total = (0..<Int(buffer.frameLength)).reduce(Float.zero) { sum, frame in
            sum + abs(samples[frame])
        }
        return total / Float(buffer.frameLength)
    }

    private func firstSample(in buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return samples[0]
    }

    private func lastSample(in buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return samples[Int(buffer.frameLength) - 1]
    }
}
