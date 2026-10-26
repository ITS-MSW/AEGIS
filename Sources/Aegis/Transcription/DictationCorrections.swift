import Foundation

@MainActor
final class DictationCorrections {
    private var task: Task<Void, Never>?

    func stop() { task?.cancel(); task = nil }

    func watch(_ text: String, range: NSRange, destination: DictationInsertion, learned: @escaping ([LearnedCorrection]) -> Void) {
        stop()
        guard let baseline = DictationInsertion.text(in: destination.element),
              let inserted = Range(range, in: baseline), String(baseline[inserted]) == text else { return }
        let prefix = String(baseline[..<inserted.lowerBound])
        let suffix = String(baseline[inserted.upperBound...])
        task = Task {
            var previous = text
            var stable = 0
            var original = text
            for _ in 0..<60 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, destination.isCurrent,
                      let value = DictationInsertion.text(in: destination.element),
                      value.hasPrefix(prefix), value.hasSuffix(suffix),
                      value.utf16.count >= prefix.utf16.count + suffix.utf16.count else { return }
                let edited = String(value.dropFirst(prefix.count).dropLast(suffix.count))
                if edited == previous { stable += 1 } else { previous = edited; stable = 0 }
                guard stable == 4, edited != original else { continue }
                let corrections = CorrectionLearner.corrections(from: original, to: edited)
                if !corrections.isEmpty { learned(corrections) }
                original = edited
            }
        }
    }
}
