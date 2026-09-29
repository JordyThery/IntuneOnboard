import AppKit
import OnboardCore
import os

/// Keyboard shortcuts for administrators: ⌃⌥⌘Q quits, ⌘L toggles the log
/// panel, and Space (provisioning only) toggles the serial barcode.
///
/// During Setup Assistant there is no Dock, Force Quit or Terminal, so these
/// are the only way to leave the window or view logs.
@MainActor
enum QuitHatch {
    private static var monitor: Any?

    /// `quit` runs before termination. `barcodeOnSpace` enables Space, which
    /// is left to focused controls during onboarding.
    static func install(quit: @escaping @Sendable () async -> Void, barcodeOnSpace: Bool = false) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if matchesEscapeHatch(event) {
                OnboardLog.app.notice("escape hatch: ⌃⌥⌘Q pressed — quitting on purpose")
                Task { @MainActor in
                    await quit()
                    AppTermination.requestExit(reason: "administrator escape hatch (⌃⌥⌘Q)")
                }
                return nil
            }

            if barcodeOnSpace, matchesBarcode(event) {
                OnboardLog.app.notice("space pressed — toggling the serial barcode window")
                BarcodeWindow.shared.toggle(over: WindowPresenter.cardWindow)
                return nil
            }

            if matchesShowLog(event) {
                OnboardLog.app.notice("⌘L pressed — toggling the log window")
                LogWindow.shared.toggle(over: WindowPresenter.cardWindow)
                return nil
            }

            return event
        }
    }

    private static func matchesEscapeHatch(_ event: NSEvent) -> Bool {
        EscapeHatch.matches(
            modifiers: modifiers(of: event),
            characters: event.charactersIgnoringModifiers
        )
    }

    /// ⌘L with no Control or Option.
    private static func matchesShowLog(_ event: NSEvent) -> Bool {
        let flags = modifiers(of: event)
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.function) else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "l"
    }

    /// Space with no modifiers.
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
