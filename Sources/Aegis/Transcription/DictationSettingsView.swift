import AppKit
import SwiftUI
import Charts
import UniformTypeIdentifiers

struct DictationSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var engine = DictationTranscriptionRunner.shared
    @ObservedObject private var microphones = DictationMicrophoneMonitor.shared
    @ObservedObject private var data = DictationData.shared
    @State private var page = "Settings"
    @State private var importing = false
    @State private var editing: DictationWord?
    @State private var adding = false
    @State private var period = 7
    @State private var resetting = false

    var body: some View {
        Section {
            Picker("Transcription", selection: $page) {
                ForEach(["Settings", "Vocabulary", "Insights"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        if page == "Settings" { controls }
        if page == "Vocabulary" { vocabulary }
        if page == "Insights" { insights }
        if let error = data.error {
            Section { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var controls: some View {
        Group {
            Section {
                Toggle("Enable dictation", isOn: Binding(get: { settings.dictationEnabled }, set: {
                    settings.dictationEnabled = $0
                    if $0 && !DictationPermissions.current().isReady { DictationPermissionSetup.shared.show() }
                }))
                Picker("Mode", selection: $settings.dictationMode) {
                    ForEach(DictationMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Shortcut", selection: $settings.dictationShiftKey) {
                    ForEach(DictationShiftKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Microphone", selection: $settings.dictationMicrophoneID) {
                    Text("Automatic").tag("")
                    ForEach(microphones.devices) { Text($0.name).tag($0.id) }
                    if !settings.dictationMicrophoneID.isEmpty && !microphones.devices.contains(where: { $0.id == settings.dictationMicrophoneID }) {
                        Text("Disconnected microphone").tag(settings.dictationMicrophoneID)
                    }
                }
                Picker("Language", selection: $settings.dictationLanguage) {
                    Text("Auto").tag("auto")
                    ForEach(DictationTranscriptionRunner.languages.sorted(by: { languageName($0) < languageName($1) }), id: \.self) {
                        Text(languageName($0)).tag($0)
                    }
                }
                Toggle("Mute system audio", isOn: $settings.dictationMuteWhileRecording)
                Toggle("Learn from corrections", isOn: $settings.dictationLearnCorrections)
                Toggle("Voice commands", isOn: $settings.dictationVoiceCommands)
                if settings.dictationVoiceCommands {
                    DisclosureGroup("Commands") {
                        LabeledContent("Comma, period, question mark", value: ", . ?")
                        LabeledContent("New line, new paragraph", value: "↵")
                        LabeledContent("At sign, percent", value: "@ %")
                        LabeledContent("Scratch that", value: "Remove the last dictated sentence")
                        Text("Commands use English. With Auto, unclear phrases stay unchanged.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Model") {
                    Text("Parakeet TDT v3").foregroundStyle(.secondary)
                    Button("Import…") { importing = true }
                        .accessibilityLabel("Import model")
                        .disabled(engine.preparing || engine.transcribing)
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                    guard case .success(let url) = result else { return }
                    Task {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        await engine.importModel(from: url)
                    }
                }
                if !engine.status.isEmpty {
                    HStack {
                        if engine.preparing { ProgressView().controlSize(.small) }
                        Text(engine.status).foregroundStyle(.secondary)
                    }
                }
                Button("Manage access…") { DictationPermissionSetup.shared.show() }
                if !settings.dictationAudioStatus.isEmpty { Text(settings.dictationAudioStatus).foregroundStyle(.red) }
                if !settings.dictationStatus.isEmpty && settings.dictationStatus != "Ready" {
                    Text(settings.dictationStatus).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func languageName(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code }

    private var vocabulary: some View {
        Section {
            HStack {
                Text("Vocabulary").font(.headline)
                Spacer()
                Button("Add phrase") { adding = true }
            }
            if data.vocabulary.isEmpty { Text("Add a phrase or correct a dictation to save its spelling.").foregroundStyle(.secondary) }
            ForEach(data.vocabulary) { word in
                HStack {
                    Text(word.heard).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(word.replacement).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit") { editing = word }.accessibilityLabel("Edit \(word.heard)")
                    Button { data.deleteWord(word.id) } label: { Image(systemName: "trash").frame(minWidth: 24, minHeight: 24) }
                        .accessibilityLabel("Delete \(word.heard)")
                }
            }
        }
        .sheet(isPresented: $adding) { DictationWordEditor(data: data, word: nil) }
        .sheet(item: $editing) { DictationWordEditor(data: data, word: $0) }
    }

    private var selectedDays: [DictationDay] {
        guard period > 0 else { return data.days.sorted { $0.id < $1.id } }
        let start = Calendar.current.date(byAdding: .day, value: 1 - period, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return (0..<period).compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = DictationDay.key(date)
            return data.days.first { $0.id == key } ?? DictationDay(id: key)
        }
    }

    private var insights: some View {
        let days = selectedDays
        let words = days.reduce(0) { $0 + $1.words }
        let sessions = days.reduce(0) { $0 + $1.sessions }
        let seconds = days.reduce(0) { $0 + $1.seconds }
        return Section {
            Picker("Period", selection: $period) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("All time").tag(0)
            }
            LabeledContent("Words", value: words.formatted())
            LabeledContent("Dictations", value: sessions.formatted())
            LabeledContent("Speaking pace", value: seconds > 0 ? "\(Int(Double(words) / seconds * 60)) words/min" : "—")
            LabeledContent("Estimated time saved", value: "\(Int(max(0, Double(words) / 52 - seconds / 60))) min")
                .help("Compared with typing 52 words per minute.")
            if sessions == 0 { Text("Your dictation activity will appear here.").foregroundStyle(.secondary) }
            else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Words", day.words))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(day.words) words")
                }
                .frame(height: 150)
                .chartYAxisLabel("Words")
            }
            Button("Reset insights", role: .destructive) { resetting = true }.disabled(data.days.isEmpty)
                .confirmationDialog("Reset all dictation insights?", isPresented: $resetting) {
                    Button("Reset insights", role: .destructive) { data.resetInsights() }
                    Button("Cancel", role: .cancel) {}
                }
        }
    }
}

private struct DictationWordEditor: View {
    @ObservedObject var data: DictationData
    let word: DictationWord?
    @Environment(\.dismiss) private var dismiss
    @State private var heard = ""
    @State private var replacement = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(word == nil ? "Add phrase" : "Edit phrase").font(.headline)
            Form {
                TextField("Heard", text: $heard)
                TextField("Replace with", text: $replacement)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try data.saveWord(id: word?.id, heard: heard, replacement: replacement); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 360)
        .onAppear { heard = word?.heard ?? ""; replacement = word?.replacement ?? "" }
    }
}
