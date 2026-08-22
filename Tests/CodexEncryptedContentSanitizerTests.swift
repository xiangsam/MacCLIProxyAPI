import XCTest
@testable import MacCLIProxyAPI

final class CodexEncryptedContentSanitizerTests: XCTestCase {
    func testDropsReasoningLinesWithEncryptedContent() {
        let keep = #"{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        let drop = #"{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"gAAAAABq..."}}"#
        let keepSummaryOnly = #"{"timestamp":"t","type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"ok"}]}}"#
        let raw = [keep, drop, keepSummaryOnly].joined(separator: "\n") + "\n"

        let rewritten = CodexEncryptedContentSanitizer.rewriteJSONLText(raw)
        XCTAssertNotNil(rewritten)
        XCTAssertEqual(rewritten?.removed, 1)
        XCTAssertTrue(rewritten!.text.contains("input_text"))
        XCTAssertTrue(rewritten!.text.contains("summary_text"))
        XCTAssertFalse(rewritten!.text.contains("encrypted_content"))
    }

    func testUnchangedWhenNoEncryptedContent() {
        let raw = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"# + "\n"
        XCTAssertNil(CodexEncryptedContentSanitizer.rewriteJSONLText(raw))
    }

    func testSanitizeTreesRewritesAndBacksUp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-strip-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archived = root.appendingPathComponent("archived", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)

        let file = sessions.appendingPathComponent("rollout.jsonl")
        let line = #"{"type":"response_item","payload":{"type":"reasoning","encrypted_content":"abc"}}"# + "\n"
            + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}"# + "\n"
        try line.write(to: file, atomically: true, encoding: .utf8)

        let result = try CodexEncryptedContentSanitizer.sanitizeSessionTrees(
            sessionsRoot: sessions,
            archivedRoot: archived,
            backupRoot: backup
        )
        XCTAssertEqual(result.filesTouched, 1)
        XCTAssertEqual(result.linesRemoved, 1)
        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("encrypted_content"))
        XCTAssertTrue(after.contains("\"role\":\"user\""))
    }
}
