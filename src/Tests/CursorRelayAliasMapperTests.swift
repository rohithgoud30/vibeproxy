import XCTest
@testable import CLIProxyMenuBar

final class CursorRelayAliasMapperTests: XCTestCase {
    private func json(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func testRewriteExtraAliasSetsModelAndReasoningEffort() {
        let input = Data(#"{"model":"gpt-5.5-extra","messages":[]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

        XCTAssertEqual(result?["model"] as? String, "gpt-5.5")
        XCTAssertEqual(result?["reasoning_effort"] as? String, "xhigh")
    }

    func testRewriteMiniExtraAlias() {
        let input = Data(#"{"model":"gpt-5.4-mini-extra"}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

        XCTAssertEqual(result?["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(result?["reasoning_effort"] as? String, "xhigh")
    }

    func testNonAliasModelPassesThroughUnchanged() {
        let input = Data(#"{"model":"gpt-5.5","messages":[]}"#.utf8)
        let output = CursorRelayAliasMapper.rewriteChatBody(input)

        XCTAssertEqual(output, input)
    }

    func testEmptyBodyPassesThrough() {
        let input = Data()
        XCTAssertEqual(CursorRelayAliasMapper.rewriteChatBody(input), input)
    }

    func testInjectAliasesAddsExtraVariants() {
        let input = Data(#"{"object":"list","data":[{"id":"gpt-5.5","object":"model"},{"id":"gpt-5.4","object":"model"}]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.injectAliases(intoModelsResponse: input))
        let ids = Set((result?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [])

        XCTAssertTrue(ids.contains("gpt-5.5"))
        XCTAssertTrue(ids.contains("gpt-5.5-extra"))
        XCTAssertTrue(ids.contains("gpt-5.4-extra"))
        XCTAssertFalse(ids.contains("gpt-5.4-mini-extra"), "alias should only be added when its base model exists")
    }

    func testInjectAliasesDoesNotDuplicateExistingAlias() {
        let input = Data(#"{"object":"list","data":[{"id":"gpt-5.5"},{"id":"gpt-5.5-extra"}]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.injectAliases(intoModelsResponse: input))
        let ids = (result?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []

        XCTAssertEqual(ids.filter { $0 == "gpt-5.5-extra" }.count, 1)
    }
}
