import AppKit
import OnboardCore
import os

/// The keyboard affordances the kiosk hides: **⌃⌥⌘Q** to get out and **⌘L**
/// to see the logs.
///
/// The kiosk modes refuse ordinary termination on purpose — ⌘Q dismissing the
/// window over Setup Assistant was a finding from the first hardware run. But
/// a Mac whose provisioning can't progress (no configuration profile, say)
/// must not be a Mac nobody can finish setting up, and during Setup Assistant
/// there is no Terminal, no Dock and no Force Quit to fall back on. The log
/// window exists for the same reason: no Console either.
///
/// Both are deliberately undocumented in the UI: a technician can find
/// them, someone unboxing a Mac won't.
@MainActor
enum QuitHatch {
    private static var monitor: Any?

    /// `quit` runs before termination — it is where the daemon is told to
    /// stop relaunching the window. `barcodeOnSpace` arms the Space toggle —
    /// kiosk modes and the provisioning demo only, because in the user-space
    /// onboarding space belongs to the focused control.
    static func install(quit: @escaping @Sendable () async -> Void, barcodeOnSpace: Bool = false) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if matchesEscapeHatch(event) {
                OnboardLog.app.notice("escape hatch: ⌃⌥⌘Q pressed — quitting on purpose")
                Task { @MainActor in
                    await quit()
                    AppTermination.requestExit(reason: "administrator escape hatch (⌃⌥⌘Q)")
                }
                return nil // swallow it
            }

            if barcodeOnSpace, matchesBarcode(event) {
                OnboardLog.app.notice("space pressed — toggling the serial barcode window")
                BarcodeWindow.shared.toggle(over: WindowPresenter.cardWindow)
                return nil
            }

            if matchesShowLog(event) {
                OnboardLog.app.notice("⌘L pressed — toggling the log window")
                // Positioned against the card and one level above it.
                LogWindow.shared.toggle(over: WindowPresenter.cardWindow)
                return nil
            }

            return event
        }
    }

    /// Thin mapping onto `EscapeHatch`, where the predicate is tested.
    private static func matchesEscapeHatch(_ event: NSEvent) -> Bool {
        EscapeHatch.matches(
            modifiers: modifiers(of: event),
            characters: event.charactersIgnoringModifiers
        )
    }

    /// ⌘L exactly: no Control, no Option, so it can't be confused with the
    /// escape hatch.
    private static func matchesShowLog(_ event: NSEvent) -> Bool {
        let flags = modifiers(of: event)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.function) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "l"
    }

    /// Space with no modifiers at all.
    private static func matchesBarcode(_ event: NSEvent) -> Bool {
        modifiers(of: event).isEmpty && event.charactersIgnoringModifiers == " "
    }

    private static func modifiers(of event: NSEvent) -> EscapeHatch.Modifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: EscapeHatch.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }
}
