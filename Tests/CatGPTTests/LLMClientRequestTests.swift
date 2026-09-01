import XCTest
@testable import CatGPT

final class LLMClientRequestTests: XCTestCase {
    func testMultiImageRequestStartsWithPromptThenPreservesImageOrder() throws {
        let body = LLMClient.makeRequestBody(
            config: makeConfig(),
            imageDataList: [Data([0x01]), Data([0x02])],
            mimeType: "image/jpeg"
        )
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])

        XCTAssertEqual(content.map { $0["type"] as? String }, ["input_text", "input_image", "input_image"])
        XCTAssertEqual(content[0]["text"] as? String, "测试提示词")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/jpeg;base64,AQ==")
        XCTAssertEqual(content[2]["image_url"] as? String, "data:image/jpeg;base64,Ag==")
    }

    func testSingleImageBodyUsesTheSamePromptAndImageLayout() throws {
        let body = LLMClient.makeRequestBody(
            config: makeConfig(),
            imageDataList: [Data([0x0A])],
            mimeType: "image/png"
        )
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])

        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,Cg==")
    }

    func testOpenAICompatibleBodyUsesChatCompletionsMultimodalFormat() throws {
        let body = LLMClient.makeOpenAICompatibleRequestBody(
            config: makeConfig(provider: .openAICompatible),
            imageDataList: [Data([0x01])],
            mimeType: "image/jpeg"
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content[1]["image_url"] as? [String: Any])

        XCTAssertEqual(body["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(messages[0]["content"] as? String, "测试指令")
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertEqual(image["url"] as? String, "data:image/jpeg;base64,AQ==")
    }

    func testOpenAICompatibleVerificationBodyIsMinimalAndNonStreaming() throws {
        let body = LLMClient.makeOpenAICompatibleVerificationRequestBody(
            config: makeConfig(provider: .openAICompatible)
        )

        XCTAssertEqual(body["model"] as? String, "gpt-5.6-terra")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "Reply with OK.")
    }

    func testOpenAICompatibleEndpointAppendsChatCompletions() {
        XCTAssertEqual(
            LLMClient.resolveOpenAICompatibleEndpoint("https://example.com/v1/")?.absoluteString,
            "https://example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            LLMClient.resolveOpenAICompatibleEndpoint("https://example.com/v1/chat/completions")?.absoluteString,
            "https://example.com/v1/chat/completions"
        )
        XCTAssertNil(LLMClient.resolveOpenAICompatibleEndpoint("example.com/v1"))
        XCTAssertNil(LLMClient.resolveOpenAICompatibleEndpoint("not a url"))
    }

    private func makeConfig(provider: LLMProvider = .codex) -> AppConfig {
        AppConfig(
            provider: provider,
            codexCredentials: CodexOAuthCredentials(access: "access", refresh: "refresh", expires: 9_999_999_999, accountId: "account"),
            customBaseURL: "https://example.com/v1",
            customAPIKey: "key",
            model: "gpt-5.6-terra", thinkingEnabled: true, reasoningEffort: .medium,
            reasoningSummary: .none, textVerbosity: .low, serviceTier: .systemDefault,
            maxOutputTokens: 0, outputDisplayMode: .floatingPanel, touchBarFontSize: 14,
            touchBarTextColor: .system, touchBarTextIntensity: 1, touchBarTextAlignment: .center,
            prompt: "测试提示词", instructions: "测试指令", maxImageEdge: 1600
        )
    }
}
