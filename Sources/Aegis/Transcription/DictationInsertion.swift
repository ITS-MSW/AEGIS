import AppKit
import ApplicationServices
import Carbon

struct DictationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DictationInsertion: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement

    static func capture(pid: pid_t) throws -> Self? {
        guard !IsSecureEventInputEnabled() else { throw DictationFailure(message: "Dictation is unavailable in password fields.") }
        guard AXIsProcessTrusted(), pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) != .success {
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            return nil
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else {
            throw DictationFailure(message: "Dictation is unavailable in password fields.")
        }
        guard editable(element) else { return nil }
        return Self(pid: pid, element: element)
    }

    @MainActor
    var isCurrent: Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let focused = try? Self.capture(pid: pid) else { return false }
        return CFEqual(focused.element, element)
    }

    private static func editable(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?, role: CFTypeRef?, enabled: CFTypeRef?, editable: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole else { return false }
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        guard enabled as? Bool != false else { return false }
        AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable)
        guard editable as? Bool != false else { return false }
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role as? String ?? "") else { return false }
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue || selectedRange(in: element) != nil
    }

    static func text(in element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        guard let text = value as? String, text.utf16.count <= 100_000 else { return nil }
        return text
    }

    static func selectedRange(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        var range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func replacing(_ range: NSRange?, in text: String?, with transcript: String) -> String? {
        guard let text, let range, let swiftRange = Range(range, in: text) else { return nil }
        return text.replacingCharacters(in: swiftRange, with: transcript)
    }

    @MainActor
    static func copy(_ text: String, to board: NSPasteboard = .general) throws {
        let saved = snapshot(board)
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            board.clearContents()
            _ = board.writeObjects(saved)
            throw DictationFailure(message: "Could not copy. Select the text below or try again.")
        }
    }

    @MainActor
    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        board.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }

    // A verified range also bounds correction learning to the text we just inserted.
    @MainActor
    func insert(_ transcript: String) async throws -> NSRange? {
        let board = NSPasteboard.general
        let saved = Self.snapshot(board)
        try Task.checkCancellation()
        try Self.copy(transcript, to: board)
        let change = board.changeCount
        guard isCurrent else { return nil }
        let before = Self.text(in: element)
        let range = Self.selectedRange(in: element)
        let expected = Self.replacing(range, in: before, with: transcript)
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false),
              isCurrent, board.changeCount == change else { return nil }
        try Task.checkCancellation()
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        let verified = try await Self.verifyPaste(before: before, expected: expected) {
            guard self.isCurrent else { return nil }
            return Self.text(in: self.element)
        }
        guard verified, let range else { return nil }
        if board.changeCount == change {
            board.clearContents()
            _ = board.writeObjects(saved)
        }
        return NSRange(location: range.location, length: (transcript as NSString).length)
    }

    @MainActor
    static func verifyPaste(before: String?, expected: String?, readText: () -> String?) async throws -> Bool {
        guard let expected, expected != before else { return false }
        // shortcut: bounded AX readback cannot acknowledge every editor; keep the clipboard when uncertain.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(50))
            let current = readText()
            if current == expected { return true }
            if current != before { return false }
        }
        return false
    }
}
