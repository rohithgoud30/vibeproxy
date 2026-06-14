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

    func testRewriteXHighFastAlias() {
        let input = Data(#"{"model":"gpt-5.4-xhigh-fast","messages":[]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

        XCTAssertEqual(result?["model"] as? String, "gpt-5.4")
        XCTAssertEqual(result?["reasoning_effort"] as? String, "xhigh")
    }

    func testRewriteAllSupportedEffortFastAliases() {
        let cases: [(alias: String, model: String, effort: String)] = [
            ("gpt-5.5-none-fast", "gpt-5.5", "none"),
            ("gpt-5.5-low-fast", "gpt-5.5", "low"),
            ("gpt-5.5-medium-fast", "gpt-5.5", "medium"),
            ("gpt-5.5-high-fast", "gpt-5.5", "high"),
            ("gpt-5.5-xhigh-fast", "gpt-5.5", "xhigh"),
            ("gpt-5.4-none-fast", "gpt-5.4", "none"),
            ("gpt-5.4-mini-high-fast", "gpt-5.4-mini", "high"),
            ("gpt-5.3-codex-low-fast", "gpt-5.3-codex", "low"),
            ("gpt-5.3-codex-xhigh-fast", "gpt-5.3-codex", "xhigh"),
            ("gpt-5.2-none-fast", "gpt-5.2", "none"),
            ("gpt-5.1-none-fast", "gpt-5.1", "none"),
            ("gpt-5-minimal-fast", "gpt-5", "minimal")
        ]

        for testCase in cases {
            let input = Data(#"{"model":"\#(testCase.alias)","messages":[]}"#.utf8)
            let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

            XCTAssertEqual(result?["model"] as? String, testCase.model, testCase.alias)
            XCTAssertEqual(result?["reasoning_effort"] as? String, testCase.effort, testCase.alias)
        }
    }

    func testRewriteFastAliasStripsClientSuffixOnly() {
        let input = Data(#"{"model":"gpt-5.4-fast","messages":[]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

        XCTAssertEqual(result?["model"] as? String, "gpt-5.4")
        XCTAssertNil(result?["reasoning_effort"])
    }

    func testRewriteFastOnlySparkAlias() {
        let input = Data(#"{"model":"gpt-5.3-codex-spark-fast","messages":[]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.rewriteChatBody(input))

        XCTAssertEqual(result?["model"] as? String, "gpt-5.3-codex-spark")
        XCTAssertNil(result?["reasoning_effort"])
    }

    func testNonAliasModelPassesThroughUnchanged() {
        let input = Data(#"{"model":"gpt-5.5","messages":[]}"#.utf8)
        let output = CursorRelayAliasMapper.rewriteChatBody(input)

        XCTAssertEqual(output, input)
    }

    func testUnsupportedEffortModelPairPassesThroughUnchanged() {
        let inputs = [
            #"{"model":"gpt-5.3-codex-none-fast","messages":[]}"#,
            #"{"model":"gpt-5.1-xhigh-fast","messages":[]}"#,
            #"{"model":"gpt-5.3-codex-spark-xhigh-fast","messages":[]}"#
        ]

        for input in inputs {
            let data = Data(input.utf8)
            XCTAssertEqual(CursorRelayAliasMapper.rewriteChatBody(data), data, input)
        }
    }

    func testEmptyBodyPassesThrough() {
        let input = Data()
        XCTAssertEqual(CursorRelayAliasMapper.rewriteChatBody(input), input)
    }

    func testInjectAliasesAddsExtraVariants() {
        let input = Data(#"{"object":"list","data":[{"id":"gpt-5.5","object":"model"},{"id":"gpt-5.4","object":"model"},{"id":"gpt-5.1","object":"model"},{"id":"gpt-5.3-codex","object":"model"},{"id":"gpt-5.3-codex-spark","object":"model"}]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.injectAliases(intoModelsResponse: input))
        let ids = Set((result?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? [])

        XCTAssertTrue(ids.contains("gpt-5.5"))
        XCTAssertTrue(ids.contains("gpt-5.5-extra"))
        XCTAssertTrue(ids.contains("gpt-5.5-low-fast"))
        XCTAssertTrue(ids.contains("gpt-5.5-xhigh-fast"))
        XCTAssertTrue(ids.contains("gpt-5.4-extra"))
        XCTAssertTrue(ids.contains("gpt-5.4-fast"))
        XCTAssertTrue(ids.contains("gpt-5.4-xhigh-fast"))
        XCTAssertTrue(ids.contains("gpt-5.1-none-fast"))
        XCTAssertTrue(ids.contains("gpt-5.3-codex-low-fast"))
        XCTAssertTrue(ids.contains("gpt-5.3-codex-xhigh-fast"))
        XCTAssertTrue(ids.contains("gpt-5.3-codex-spark-fast"))
        XCTAssertFalse(ids.contains("gpt-5.1-xhigh-fast"), "alias should only be added when the model supports that effort")
        XCTAssertFalse(ids.contains("gpt-5.3-codex-none-fast"), "alias should only be added when the model supports that effort")
        XCTAssertFalse(ids.contains("gpt-5.3-codex-spark-xhigh-fast"), "spark only gets the fast suffix stripped")
        XCTAssertFalse(ids.contains("gpt-5.4-mini-extra"), "alias should only be added when its base model exists")
    }

    func testInjectAliasesDoesNotDuplicateExistingAlias() {
        let input = Data(#"{"object":"list","data":[{"id":"gpt-5.5"},{"id":"gpt-5.5-extra"}]}"#.utf8)
        let result = json(from: CursorRelayAliasMapper.injectAliases(intoModelsResponse: input))
        let ids = (result?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []

        XCTAssertEqual(ids.filter { $0 == "gpt-5.5-extra" }.count, 1)
    }
}
