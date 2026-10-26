import Foundation
import Combine
import ServiceManagement

final class SettingsStore: ObservableObject {
    @Published var dictationEnabled: Bool {
        didSet { UserDefaults.standard.set(dictationEnabled, forKey: "dictationEnabled") }
    }
    @Published var dictationMode: DictationMode {
        didSet { UserDefaults.standard.set(dictationMode.rawValue, forKey: "dictationMode") }
    }
    @Published var dictationShiftKey: DictationShiftKey {
        didSet { UserDefaults.standard.set(dictationShiftKey.rawValue, forKey: "dictationShiftKey") }
    }
    @Published var dictationMicrophoneID: String {
        didSet { UserDefaults.standard.set(dictationMicrophoneID, forKey: "dictationMicrophoneID") }
    }
    @Published var dictationMuteWhileRecording: Bool {
        didSet { UserDefaults.standard.set(dictationMuteWhileRecording, forKey: "dictationMuteWhileRecording") }
    }
    @Published var dictationLanguage: String {
        didSet { UserDefaults.standard.set(dictationLanguage, forKey: "dictationLanguage") }
    }
    @Published var dictationLearnCorrections: Bool {
        didSet { UserDefaults.standard.set(dictationLearnCorrections, forKey: "dictationLearnCorrections") }
    }
    @Published var dictationVoiceCommands: Bool {
        didSet { UserDefaults.standard.set(dictationVoiceCommands, forKey: "dictationVoiceCommands") }
    }
    @Published var dictationAudioStatus = ""
    @Published var dictationStatus = ""

    static func registerDictationDefaults(_ defaults: UserDefaults) {
        defaults.register(defaults: ["dictationEnabled": false, "dictationMode": "toggle",
                                     "dictationShiftKey": "either", "dictationMicrophoneID": "", "dictationMuteWhileRecording": false,
                                     "dictationLanguage": "auto", "dictationLearnCorrections": true, "dictationVoiceCommands": true])
    }

    func resetDictationShortcut() { dictationShiftKey = .either }

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var soundVolume: Float {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    @Published var soundProfile: SoundProfile {
        didSet { UserDefaults.standard.set(soundProfile.rawValue, forKey: "soundProfile") }
    }
    @Published var showSubagents: Bool {
        didSet { UserDefaults.standard.set(showSubagents, forKey: "showSubagents") }
    }
    @Published var keepAwakeMode: AgentKeepAwakeMode {
        didSet { UserDefaults.standard.set(keepAwakeMode.rawValue, forKey: "keepAwakeMode") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has seen the redesigned (themed, full-screen) onboarding.
    /// Separate from `hasCompletedOnboarding` so existing users — who already
    /// completed the OLD onboarding — get shown the new one once on update, then
    /// never again. Fresh installs see it via this flag being false too.
    @Published var hasSeenThemeOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenThemeOnboarding, forKey: "hasSeenThemeOnboarding") }
    }

    /// Selected typography and mascot styling for the compact notch. Persisted by raw value.
    @Published var notchThemeID: NotchThemeID {
        didSet { UserDefaults.standard.set(notchThemeID.rawValue, forKey: "notchThemeID") }
    }

    /// Last app version for which we showed the "What's New" card. Shown once
    /// per version bump (returning users on update); fresh installs get
    /// onboarding instead and have this stamped to the current version.
    @Published var lastWhatsNewVersion: String {
        didSet { UserDefaults.standard.set(lastWhatsNewVersion, forKey: "lastWhatsNewVersion") }
    }

    /// Per-event sound assignment: `SoundEvent.rawValue` → "default" | "off" |
    /// "<library filename>". Missing key = "default". Persisted as JSON.
    @Published var soundAssignments: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(soundAssignments) {
                UserDefaults.standard.set(data, forKey: "soundAssignments")
            }
        }
    }
    func soundChoice(for eventRaw: String) -> String { soundAssignments[eventRaw] ?? "default" }
    func setSoundChoice(_ choice: String, for eventRaw: String) { soundAssignments[eventRaw] = choice }

    /// Per-event gain applied after the selected built-in or custom sound.
    @Published var soundEventVolumes: [String: Float] {
        didSet {
            if let data = try? JSONEncoder().encode(soundEventVolumes) {
                UserDefaults.standard.set(data, forKey: "soundEventVolumes")
            }
        }
    }
    func soundEventVolume(for eventRaw: String) -> Float { soundEventVolumes[eventRaw] ?? 1 }
    func setSoundEventVolume(_ volume: Float, for eventRaw: String) {
        soundEventVolumes[eventRaw] = max(0, min(1, volume))
    }

    static let supportedAudioExts = ["wav", "mp3", "m4a", "aiff", "caf"]

    /// The sound library = audio files the user has imported (and any legacy
    /// event-named files), living in `~/.aegis/sound-packs/`.
    func soundLibraryDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aegis/sound-packs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func soundLibraryFiles() -> [String] {
        let dir = soundLibraryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { Self.supportedAudioExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
    /// Copy an imported file into the library (de-duping the name). Returns the stored filename.
    @discardableResult
    func importSound(from url: URL) -> String? {
        let dir = soundLibraryDirectory()
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        var name = url.lastPathComponent
        var dest = dir.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(base)-\(i).\(ext)"; dest = dir.appendingPathComponent(name); i += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            objectWillChange.send()
            return name
        } catch { return nil }
    }
    func deleteSound(_ filename: String) {
        try? FileManager.default.removeItem(at: soundLibraryDirectory().appendingPathComponent(filename))
        for (k, v) in soundAssignments where v == filename { soundAssignments[k] = "default" }
        objectWillChange.send()
    }

    init() {
        Self.migrateLegacyInstallationIfNeeded()
        let defaults = UserDefaults.standard
        Self.registerDictationDefaults(defaults)
        dictationLanguage = defaults.string(forKey: "dictationLanguage") ?? "auto"
        dictationLearnCorrections = defaults.bool(forKey: "dictationLearnCorrections")
        dictationVoiceCommands = defaults.bool(forKey: "dictationVoiceCommands")
        dictationEnabled = defaults.bool(forKey: "dictationEnabled")
        dictationMode = DictationMode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .toggle
        dictationShiftKey = DictationShiftKey(rawValue: defaults.string(forKey: "dictationShiftKey") ?? "") ?? .either
        dictationMuteWhileRecording = defaults.bool(forKey: "dictationMuteWhileRecording")
        dictationMicrophoneID = defaults.string(forKey: "dictationMicrophoneID") ?? ""
        // Register defaults
        defaults.register(defaults: [
            "soundEnabled": true,
            "soundVolume": Float(0.7),
            "soundProfile": SoundProfile.quietGlass.rawValue,
            "showSubagents": false,
            "keepAwakeMode": AgentKeepAwakeMode.off.rawValue,
            "launchAtLogin": false,
            "hasCompletedOnboarding": false,
            "soundError": true,
            "notchThemeID": NotchThemeID.aegis.rawValue,
            "hasSeenThemeOnboarding": false,
        ])

        self.soundEnabled = defaults.bool(forKey: "soundEnabled")
        self.soundVolume = defaults.float(forKey: "soundVolume")
        let storedSoundProfile = defaults.string(forKey: "soundProfile")
        self.soundProfile = Self.resolveSoundProfile(rawValue: storedSoundProfile)
        if storedSoundProfile == "yamete-kudasai" {
            defaults.set(SoundProfile.meme.rawValue, forKey: "soundProfile")
        }
        self.showSubagents = defaults.bool(forKey: "showSubagents")
        self.keepAwakeMode = AgentKeepAwakeMode(
            rawValue: defaults.string(forKey: "keepAwakeMode") ?? ""
        ) ?? .off
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        // Keep only active events, preserving their custom sounds and Off choices.
        if let data = defaults.data(forKey: "soundAssignments"),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            self.soundAssignments = map.filter { SoundEvent(rawValue: $0.key) != nil }
        } else {
            var assignments: [String: String] = [:]
            if let enabled = defaults.object(forKey: "soundSessionStart") as? Bool, !enabled {
                assignments[SoundEvent.sessionEnd.rawValue] = "off"
            }
            if !defaults.bool(forKey: "soundError") { assignments[SoundEvent.error.rawValue] = "off" }
            self.soundAssignments = assignments
        }
        if let data = defaults.data(forKey: "soundEventVolumes"),
           let map = try? JSONDecoder().decode([String: Float].self, from: data) {
            self.soundEventVolumes = map.filter { SoundEvent(rawValue: $0.key) != nil }
                .mapValues { max(0, min(1, $0)) }
        } else {
            self.soundEventVolumes = [:]
        }
        var selectedTheme = NotchThemeID(rawValue: defaults.string(forKey: "notchThemeID") ?? "") ?? .aegis
        if defaults.integer(forKey: "appearanceVersion") < 2 {
            selectedTheme = .aegis
            defaults.set(NotchThemeID.aegis.rawValue, forKey: "notchThemeID")
            defaults.set(2, forKey: "appearanceVersion")
        }
        self.notchThemeID = selectedTheme
        self.hasSeenThemeOnboarding = defaults.bool(forKey: "hasSeenThemeOnboarding")
        self.lastWhatsNewVersion = defaults.string(forKey: "lastWhatsNewVersion") ?? ""

        defaults.set(try? JSONEncoder().encode(soundAssignments), forKey: "soundAssignments")
        defaults.set(try? JSONEncoder().encode(soundEventVolumes), forKey: "soundEventVolumes")
        if launchAtLogin { updateLoginItem() }
    }

    static func resolveSoundProfile(rawValue: String?) -> SoundProfile {
        if rawValue == "yamete-kudasai" { return .meme }
        return SoundProfile(rawValue: rawValue ?? "") ?? .quietGlass
    }

    private static func migrateLegacyInstallationIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "aegisLegacyIdentityMigrationCompleted"
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let legacyDomain = defaults.persistentDomain(forName: "dev.caesura.island") {
            for (key, value) in legacyDomain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let legacySounds = home.appendingPathComponent(".caesura-island/sound-packs", isDirectory: true)
        let currentSounds = home.appendingPathComponent(".aegis/sound-packs", isDirectory: true)
        if let filenames = try? fileManager.contentsOfDirectory(atPath: legacySounds.path) {
            try? fileManager.createDirectory(at: currentSounds, withIntermediateDirectories: true)
            for filename in filenames {
                let source = legacySounds.appendingPathComponent(filename)
                let destination = currentSounds.appendingPathComponent(filename)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try? fileManager.copyItem(at: source, to: destination)
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("[Aegis] Login item error: \(error)")
        }
    }
}
