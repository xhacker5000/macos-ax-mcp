import AppKit

/// Snapshot of every pasteboard item and every type's raw Data, restored deterministically.
final class ClipboardGuard {
    struct ItemSnapshot: Equatable {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]

        static func == (l: ItemSnapshot, r: ItemSnapshot) -> Bool {
            l.entries.count == r.entries.count
                && zip(l.entries, r.entries).allSatisfy { $0.type == $1.type && $0.data == $1.data }
        }
    }

    /// nspasteboard.org markers so clipboard managers ignore our temporary path.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    let pasteboard: NSPasteboard
    let items: [ItemSnapshot]
    let changeCountAtCapture: Int
    private(set) var restored = false

    private init(pasteboard: NSPasteboard, items: [ItemSnapshot]) {
        self.pasteboard = pasteboard
        self.items = items
        self.changeCountAtCapture = pasteboard.changeCount
    }

    static func capture(_ pasteboard: NSPasteboard = .general) -> ClipboardGuard {
        ClipboardGuard(pasteboard: pasteboard, items: snapshotItems(pasteboard))
    }

    static func snapshotItems(_ pasteboard: NSPasteboard) -> [ItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            let entries = item.types.compactMap { t -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let d = item.data(forType: t) else { return nil } // unresolvable promise
                return (t, d)
            }
            return entries.isEmpty ? nil : ItemSnapshot(entries: entries)
        }
    }

    /// Restores the captured contents. Idempotent; skips work when nobody touched the pasteboard.
    @discardableResult
    func restore() -> Bool {
        guard !restored else { return false }
        restored = true
        if pasteboard.changeCount == changeCountAtCapture { return true }
        pasteboard.clearContents()
        if items.isEmpty { return true }
        let objects: [NSPasteboardItem] = items.map { snap in
            let item = NSPasteboardItem()
            for e in snap.entries { item.setData(e.data, forType: e.type) }
            return item
        }
        return pasteboard.writeObjects(objects)
    }

    /// Writes a temporary plain string marked transient/concealed.
    @discardableResult
    static func writeTransientString(_ s: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, transientType, concealedType], owner: nil)
        let ok = pasteboard.setString(s, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
        return ok
    }
}
