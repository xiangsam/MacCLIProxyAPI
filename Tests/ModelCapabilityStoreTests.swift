import AppKit
import SwiftUI
import XCTest
@testable import MacCLIProxyAPI

final class ModelCapabilityStoreTests: XCTestCase {
    private let fixture = Data(#"""
    {
      "models": {
        "lab/model": {"name":"Model", "reasoning":true, "modalities":{"input":["text","image"],"output":["text"]}, "limit":{"context":100000,"output":8000}},
        "lab/unknown": {"name":"Unknown"},
        "lab/no-thinking": {"reasoning":false}
      },
      "providers": {
        "first": {"name":"First", "models": {
          "alias": {"canonical_model_id":"lab/model", "reasoning":true, "reasoning_options":[{"type":"effort","values":[null,"low","high"]}], "limit":{"context":32000}, "modalities":{"input":["text"]}}
        }},
        "second": {"name":"Second", "models": {
          "other-id": {"canonical_model_id":"lab/model", "reasoning_options":[{"type":"budget_tokens","min":1024,"max":8192},{"type":"toggle"}]},
          "model": {"name":"Model", "reasoning":true}
        }}
      }
    }
    """#.utf8)

    func testOneRecordPerCanonicalModelRetainsProviderDifferences() throws {
        let snapshot = try ModelCapabilityStore.parse(fixture)
        XCTAssertEqual(snapshot.models.count, 3)
        XCTAssertEqual(Set(snapshot.models.map(\.id)).count, 3)
        let model = try XCTUnwrap(snapshot.models.first { $0.id == "lab/model" })
        XCTAssertEqual(model.contextWindow, 100000)
        XCTAssertEqual(model.inputModalities, ["text", "image"])
        XCTAssertEqual(model.reasoningLevels, ["high", "low"])
        XCTAssertEqual(model.reasoningLevelsScope, "provider-dependent")
        XCTAssertEqual(model.providerVariants.count, 2)
        XCTAssertEqual(model.providerVariants[0].reasoningOptions?.first?.values?.count, 3)
        XCTAssertNil(model.providerVariants[0].reasoningOptions?.first?.values?[0])
        XCTAssertEqual(model.providerVariants[0].contextWindow, 32000)
        XCTAssertEqual(model.providerVariants[0].inputModalities, ["text"])
        XCTAssertEqual(model.providerVariants[1].reasoningOptions?.first?.min, 1024)
        XCTAssertEqual(snapshot.unmappedProviderModelCount, 1)
    }

    func testMissingFactsStayUnknownAndFalseIsNotUnknown() throws {
        let snapshot = try ModelCapabilityStore.parse(fixture)
        let unknown = try XCTUnwrap(snapshot.models.first { $0.id == "lab/unknown" })
        XCTAssertNil(unknown.reasoning)
        XCTAssertNil(unknown.reasoningLevels)
        XCTAssertNil(unknown.contextWindow)
        XCTAssertNil(unknown.inputModalities)
        XCTAssertEqual(unknown.reasoningSummary, "未提供")
        XCTAssertEqual(snapshot.models.first { $0.id == "lab/no-thinking" }?.reasoningSummary, "不支持")
    }

    func testCacheRoundTripAndRejectedPayloadDoesNotReplaceCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capabilities.json")
        let snapshot = try ModelCapabilityStore.parse(fixture, fetchedAt: Date(timeIntervalSince1970: 100))
        try ModelCapabilityStore.save(snapshot, to: url)
        XCTAssertThrowsError(try ModelCapabilityStore.parse(Data(#"{"models":{},"providers":{}}"#.utf8)))
        XCTAssertThrowsError(try ModelCapabilityStore.parse(Data("not json".utf8)))
        XCTAssertEqual(try ModelCapabilityStore.load(from: url), snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["fetchedAt"] as? String, "1970-01-01T00:01:40Z")
    }
    @MainActor
    func testModelListRendersAtMinimumDetailWidth() throws {
        let snapshot = try ModelCapabilityStore.parse(fixture)
        let view = NSHostingView(rootView: ModelCapabilitiesPageView(initialSnapshot: snapshot).environment(AppState()).background(Color.white).environment(\.colorScheme, .light))
        let rect = NSRect(x: 0, y: 0, width: 780, height: 680)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.frame = rect
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: URL(fileURLWithPath: "/tmp/maccli-model-capabilities.png"))
    }

}
