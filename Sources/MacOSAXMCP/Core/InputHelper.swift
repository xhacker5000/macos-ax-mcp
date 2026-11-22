import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum KeyCode {
    static let a = CGKeyCode(kVK_ANSI_A)        // 0x00
    static let g = CGKeyCode(kVK_ANSI_G)        // 0x05
    static let v = CGKeyCode(kVK_ANSI_V)        // 0x09
    static let returnKey = CGKeyCode(kVK_Return) // 0x24
}

/// Hardware-keycode CGEvent synthesis. Never types characters (IME/CJK-safe by construction).
enum InputHelper {
    private static func source() -> CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    /// Posts keyDown+keyUp with explicit modifier flags (physically held modifiers are overridden).
    @discardableResult
    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let src = source(),
              let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
        usleep(15_000)
        return true
    }

    @discardableResult static func cmdShiftG() -> Bool { key(KeyCode.g, flags: [.maskCommand, .maskShift]) }
    @discardableResult static func cmdA() -> Bool { key(KeyCode.a, flags: .maskCommand) }
    @discardableResult static func cmdV() -> Bool { key(KeyCode.v, flags: .maskCommand) }
    @discardableResult static func pressReturn() -> Bool { key(KeyCode.returnKey) }

    static func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }

    static func warpCursor(to p: CGPoint) {
        _ = CGWarpMouseCursorPosition(p)
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Left click at a global (top-left origin) point. Restores the cursor afterwards when asked.
    @discardableResult
    static func click(at p: CGPoint, restoreCursor: Bool = true) -> Bool {
        let original = cursorLocation()
        guard let src = source(),
              let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left),
              let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        move.post(tap: .cghidEventTap)
        usleep(25_000)
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        usleep(30_000)
        if restoreCursor, let original { warpCursor(to: original) }
        return true
    }
}
