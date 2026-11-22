import AppKit
import XCTest
@testable import MacOSAXMCP

final class FileDialogValidationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macos-ax-mcp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func code(_ block: () throws -> Any) -> String? {
        do { _ = try block(); return nil } catch let e as ToolError { return e.code } catch { return "other" }
    }

    func testValidatesExistingFileWithCJKNameAndSymlink() throws {
        let file = dir.appendingPathComponent("测试 视频 🎬.mp4")
        try Data(count: 12345).write(to: file)
        let link = dir.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let v = try FileValidation.validate(file.path)
        XCTAssertEqual(v.sizeBytes, 12345)
        XCTAssertFalse(v.isDirectory)
        XCTAssertTrue(v.path.hasSuffix("测试 视频 🎬.mp4"))

        let viaLink = try FileValidation.validate(link.path)
        XCTAssertEqual(viaLink.path, v.path, "symlinks resolved")

        let dotted = try FileValidation.validate(dir.appendingPathComponent("./sub/../测试 视频 🎬.mp4").path)
        XCTAssertEqual(dotted.path, v.path, "path standardized")
    }

    func testTildeExpansion() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let v = try FileValidation.validate("~")
        XCTAssertEqual(v.path, URL(fileURLWithPath: home).resolvingSymlinksInPath().path)
        XCTAssertTrue(v.isDirectory)
    }

    func testErrorCodes() {
        XCTAssertEqual(code { try FileValidation.validate("relative/file.mp4") }, ErrorCode.invalidPath)
        XCTAssertEqual(code { try FileValidation.validate("/tmp/a\nb") }, ErrorCode.invalidPath)
        XCTAssertEqual(code { try FileValidation.validate(dir.appendingPathComponent("missing.mp4").path) }, ErrorCode.fileNotFound)
    }

    func testArgumentValidation() {
        XCTAssertEqual(code { try FileDialogTool.run(Args([:]), trustCheck: { true }) }, ErrorCode.invalidArgument)
        XCTAssertEqual(code { try FileDialogTool.run(Args(["file_path": "/x", "timeout_ms": 999]), trustCheck: { true }) }, ErrorCode.invalidArgument)
        XCTAssertEqual(code { try FileDialogTool.run(Args(["file_path": "/x", "timeout_ms": 30001]), trustCheck: { true }) }, ErrorCode.invalidArgument)
        XCTAssertEqual(code { try FileDialogTool.run(Args(["file_path": "/x", "restore_focus": "yes"]), trustCheck: { true }) }, ErrorCode.invalidArgument)
        XCTAssertEqual(code { try FileDialogTool.run(Args(["file_path": 42]), trustCheck: { true }) }, ErrorCode.invalidArgument)
    }

    func testUntrustedFailsBeforeFileCheck() {
        XCTAssertEqual(code { try FileDialogTool.run(Args(["file_path": "/definitely/missing"]), trustCheck: { false }) },
                       ErrorCode.tccUntrusted)
    }

    func testMissingFileFailsFastWithoutTouchingFocusOrClipboard() throws {
        let pbCount = NSPasteboard.general.changeCount
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let start = Date()
        do {
            _ = try FileDialogTool.run(Args(["file_path": .string(dir.appendingPathComponent("nope.mp4").path),
                                             "app_name": "Google Chrome"]), trustCheck: { true })
            XCTFail("expected failure")
        } catch let e as ToolError {
            XCTAssertEqual(e.code, ErrorCode.fileNotFound)
            let trace = e.extra["steps_trace"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertFalse(trace.contains { $0.contains("snapshot:") }, "must fail before state snapshot / UI work: \(trace)")
            XCTAssertNotNil(e.extra["elapsed_ms"]?.intValue)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(NSPasteboard.general.changeCount, pbCount, "clipboard untouched")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front, "focus untouched")
    }

    func testConfirmTitleLocalization() {
        for t in ["Open", "open", " 打开 ", "Upload", "上传", "Choose", "选择", "Choose…", "Open..."] {
            XCTAssertTrue(DialogFinder.matchesConfirmTitle(t), t)
        }
        for t in ["Cancel", "取消", "Opened", "", nil] as [String?] {
            XCTAssertFalse(DialogFinder.matchesConfirmTitle(t), t ?? "nil")
        }
    }

    func testForbiddenAttributeIsNeverWritten() {
        let err = AX.setAttribute(AXUIElementCreateSystemWide(), "AXEnhancedUserInterface", kCFBooleanTrue)
        XCTAssertEqual(err, .attributeUnsupported)
    }
}
