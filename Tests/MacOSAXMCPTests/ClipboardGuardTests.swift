import AppKit
import XCTest
@testable import MacOSAXMCP

/// Uses a private named pasteboard so the developer's real clipboard is never touched.
final class ClipboardGuardTests: XCTestCase {
    private var pb: NSPasteboard!

    override func setUp() {
        pb = NSPasteboard(name: NSPasteboard.Name("macos-ax-mcp-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pb.releaseGlobally()
    }

    private static let customType = NSPasteboard.PasteboardType("com.example.macos-ax-mcp.binary")

    private func makePNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(.systemRed, atX: 1, y: 1)
        return rep.representation(using: .png, properties: [:])!
    }

    func testMultiItemMultiTypeRoundTrip() throws {
        let rtf = try NSAttributedString(string: "富文本 RTF").data(
            from: NSRange(location: 0, length: 7), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let binary = Data((0..<1024).map { UInt8($0 % 256) })

        let item1 = NSPasteboardItem()
        item1.setString("纯文本 plain ✓", forType: .string)
        item1.setData(rtf, forType: .rtf)
        item1.setData(binary, forType: Self.customType)
        let item2 = NSPasteboardItem()
        item2.setData(makePNG(), forType: .png)
        item2.setString("https://example.com/路径", forType: .URL)
        pb.clearContents()
        XCTAssertTrue(pb.writeObjects([item1, item2]))

        let before = ClipboardGuard.snapshotItems(pb)
        XCTAssertEqual(before.count, 2)

        let guardian = ClipboardGuard.capture(pb)
        XCTAssertTrue(ClipboardGuard.writeTransientString("/tmp/中文 路径/video.mp4", to: pb))
        XCTAssertEqual(pb.string(forType: .string), "/tmp/中文 路径/video.mp4")
        XCTAssertNotNil(pb.data(forType: ClipboardGuard.transientType))

        XCTAssertTrue(guardian.restore())
        let after = ClipboardGuard.snapshotItems(pb)
        XCTAssertEqual(after, before)
        XCTAssertEqual(pb.pasteboardItems?.count, 2)
        XCTAssertEqual(pb.pasteboardItems?[0].string(forType: .string), "纯文本 plain ✓")
        XCTAssertEqual(pb.pasteboardItems?[0].data(forType: Self.customType), binary)
        XCTAssertEqual(pb.pasteboardItems?[1].data(forType: .png), before[1].entries.first { $0.type == .png }?.data)
        XCTAssertNil(pb.data(forType: ClipboardGuard.transientType))
    }

    func testEmptyPasteboardRestoredToEmpty() {
        pb.clearContents()
        let guardian = ClipboardGuard.capture(pb)
        XCTAssertTrue(guardian.items.isEmpty)
        ClipboardGuard.writeTransientString("temp", to: pb)
        guardian.restore()
        XCTAssertTrue((pb.pasteboardItems ?? []).isEmpty)
    }

    func testRestoreIsIdempotentAndSkipsUntouched() {
        pb.clearContents()
        pb.setString("keep", forType: .string)
        let guardian = ClipboardGuard.capture(pb)
        let count = pb.changeCount
        XCTAssertTrue(guardian.restore())
        XCTAssertEqual(pb.changeCount, count, "untouched pasteboard must not be rewritten")
        XCTAssertFalse(guardian.restore(), "second restore is a no-op")
        XCTAssertEqual(pb.string(forType: .string), "keep")
    }
}
