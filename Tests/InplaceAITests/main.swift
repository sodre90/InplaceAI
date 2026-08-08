import Foundation

// MARK: - Assertions

@MainActor
final class TestRun {
    private(set) var passed = 0
    private(set) var failed = 0

    func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
        do {
            try await body()
            passed += 1
            print("  ✅ \(name)")
        } catch {
            failed += 1
            print("  ❌ \(name)\n     \(error)")
        }
    }

    func summarize() -> Never {
        print("\n📊 \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw Failure(description: message()) }
}

func expectEqual<T: Equatable>(_ actual: T?, _ expected: T?, _ label: String) throws {
    guard actual == expected else {
        let expectedText = expected.map { "\($0)" } ?? "nil"
        let actualText = actual.map { "\($0)" } ?? "nil"
        throw Failure(description: "\(label): expected \(expectedText), got \(actualText)")
    }
}

func expectThrows(_ label: String, _ body: @MainActor () async throws -> Void) async throws -> Error {
    do {
        try await body()
    } catch {
        return error
    }
    throw Failure(description: "\(label): expected a thrown error, but the call succeeded")
}

func unwrap<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw Failure(description: "\(label): unexpectedly nil") }
    return value
}

// MARK: - Request capture

/// Captures the outgoing request instead of hitting the network, then replays a
/// canned response. Registered through an ephemeral session config so nothing
/// leaks into `URLSession.shared`.
final class RequestCapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    nonisolated(unsafe) static var stubbedStatusCode = 200
    nonisolated(unsafe) static var stubbedBody = Data()

    static let defaultBody = Data(#"{"choices":[{"message":{"role":"assistant","content":"rewritten"}}]}"#.utf8)

    static func reset() {
        capturedRequest = nil
        stubbedStatusCode = 200
        stubbedBody = defaultBody
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestCapturingProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// `URLSession` moves a request's `httpBody` into `httpBodyStream` before it
    /// reaches the protocol, so the body has to be drained from the stream.
    static func capturedJSONBody() throws -> [String: Any] {
        let request = try unwrap(capturedRequest, "captured request")
        let data = try request.httpBody ?? unwrap(request.httpBodyStream, "request body stream").drained()
        return try unwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "JSON body")
    }

    static func capturedChatTemplateKwargs() throws -> [String: Any] {
        try unwrap(capturedJSONBody()["chat_template_kwargs"] as? [String: Any], "chat_template_kwargs")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        RequestCapturingProtocol.capturedRequest = request

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: RequestCapturingProtocol.stubbedStatusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: RequestCapturingProtocol.stubbedBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension InputStream {
    func drained() -> Data {
        open()
        defer { close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while hasBytesAvailable {
            let read = self.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

@discardableResult
func sendRewrite(
    reasoningDisabled: Bool = false,
    maxTokens: Int = 1000,
    baseURL: String = "https://example.invalid/v1",
    apiKey: String = "test-key"
) async throws -> Suggestion {
    try await OpenAIService(session: RequestCapturingProtocol.session()).rewrite(
        text: "hello",
        instruction: "fix grammar",
        apiKey: apiKey,
        model: "test-model",
        baseURL: baseURL,
        reasoningDisabled: reasoningDisabled,
        maxTokens: maxTokens
    )
}

// MARK: - Tests

let run = TestRun()
print("🚀 InplaceAI tests\n")

print("OpenAIService — reasoning toggle")

// llama.cpp rejects the string form outright with `invalid type for
// "enable_thinking" (expected boolean, got string)`, and Qwen3-style Jinja
// templates test it with `is false`.
await run.test("reasoning disabled sends enable_thinking as boolean false") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(reasoningDisabled: true)

    let kwargs = try RequestCapturingProtocol.capturedChatTemplateKwargs()
    try expect(kwargs["enable_thinking"] is Bool, "enable_thinking must encode as a JSON boolean, not a string")
    try expectEqual(kwargs["enable_thinking"] as? Bool, false, "enable_thinking")
}

await run.test("reasoning enabled sends enable_thinking as boolean true") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(reasoningDisabled: false)

    let kwargs = try RequestCapturingProtocol.capturedChatTemplateKwargs()
    try expect(kwargs["enable_thinking"] is Bool, "enable_thinking must encode as a JSON boolean, not a string")
    try expectEqual(kwargs["enable_thinking"] as? Bool, true, "enable_thinking")
}

await run.test("reasoning_effort is sent only when reasoning is disabled") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(reasoningDisabled: true)
    try expectEqual(
        try RequestCapturingProtocol.capturedJSONBody()["reasoning_effort"] as? String,
        "none",
        "reasoning_effort when disabled"
    )

    RequestCapturingProtocol.reset()
    try await sendRewrite(reasoningDisabled: false)
    try expect(
        try RequestCapturingProtocol.capturedJSONBody()["reasoning_effort"] == nil,
        "reasoning_effort has no defined 'on' value, so it must be omitted when reasoning is enabled"
    )
}

print("\nOpenAIService — request shape")

await run.test("request carries model, max_tokens, and both prompt messages") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(maxTokens: 2500)

    let body = try RequestCapturingProtocol.capturedJSONBody()
    try expectEqual(body["model"] as? String, "test-model", "model")
    try expectEqual(body["max_tokens"] as? Int, 2500, "max_tokens")

    let messages = try unwrap(body["messages"] as? [[String: Any]], "messages")
    try expectEqual(messages.count, 2, "message count")
    try expectEqual(messages.first?["role"] as? String, "system", "first role")
    try expectEqual(messages.last?["role"] as? String, "user", "last role")

    let userContent = try unwrap(messages.last?["content"] as? String, "user content")
    try expect(userContent.contains("fix grammar"), "user message must carry the instruction")
    try expect(userContent.contains("hello"), "user message must carry the selected text")
}

await run.test("base URL without a trailing slash still resolves chat/completions") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(baseURL: "https://example.invalid/v1")

    try expectEqual(
        RequestCapturingProtocol.capturedRequest?.url?.absoluteString,
        "https://example.invalid/v1/chat/completions",
        "resolved URL"
    )
}

await run.test("base URL with a trailing slash does not double up") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(baseURL: "https://example.invalid/v1/")

    try expectEqual(
        RequestCapturingProtocol.capturedRequest?.url?.absoluteString,
        "https://example.invalid/v1/chat/completions",
        "resolved URL"
    )
}

await run.test("empty API key omits the Authorization header") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(apiKey: "")

    try expect(
        RequestCapturingProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == nil,
        "local servers are commonly keyless; an empty Bearer token can be rejected"
    )
}

await run.test("API key is sent as a Bearer token") {
    RequestCapturingProtocol.reset()
    try await sendRewrite(apiKey: "secret")

    try expectEqual(
        RequestCapturingProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization"),
        "Bearer secret",
        "Authorization header"
    )
}

await run.test("non-http(s) base URL throws") {
    RequestCapturingProtocol.reset()
    _ = try await expectThrows("ftp base URL") {
        try await sendRewrite(baseURL: "ftp://example.invalid/v1")
    }
}

print("\nOpenAIService — response handling")

await run.test("successful response is returned verbatim") {
    RequestCapturingProtocol.reset()
    let suggestion = try await sendRewrite()

    try expectEqual(suggestion.originalText, "hello", "originalText")
    try expectEqual(suggestion.rewrittenText, "rewritten", "rewrittenText")
}

// Masking a leaked <think> block would hide a future regression of the
// reasoning toggle, so the content is deliberately passed through untouched.
await run.test("leaked <think> block is left intact so a toggle regression stays visible") {
    RequestCapturingProtocol.reset()
    RequestCapturingProtocol.stubbedBody = Data(
        #"{"choices":[{"message":{"role":"assistant","content":"<think>reasoning</think>answer"}}]}"#.utf8
    )

    let suggestion = try await sendRewrite(reasoningDisabled: true)
    try expectEqual(suggestion.rewrittenText, "<think>reasoning</think>answer", "rewrittenText")
}

await run.test("non-2xx response throws ServiceError.http carrying status and body") {
    RequestCapturingProtocol.reset()
    RequestCapturingProtocol.stubbedStatusCode = 401
    RequestCapturingProtocol.stubbedBody = Data(#"{"error":"Invalid API Key"}"#.utf8)

    let error = try await expectThrows("HTTP 401") { try await sendRewrite() }
    guard case .http(let statusCode, let body)? = error as? ServiceError else {
        throw Failure(description: "expected ServiceError.http, got \(error)")
    }
    try expectEqual(statusCode, 401, "status code")
    try expect(body.contains("Invalid API Key"), "error body must be surfaced")
}

await run.test("blank content throws ServiceError.emptyModelResponse") {
    RequestCapturingProtocol.reset()
    RequestCapturingProtocol.stubbedBody = Data(
        #"{"choices":[{"message":{"role":"assistant","content":"   "}}]}"#.utf8
    )

    let error = try await expectThrows("blank content") { try await sendRewrite() }
    guard case .emptyModelResponse? = error as? ServiceError else {
        throw Failure(description: "expected ServiceError.emptyModelResponse, got \(error)")
    }
}

await run.test("overlong error body is truncated before it reaches the alert") {
    RequestCapturingProtocol.reset()
    RequestCapturingProtocol.stubbedStatusCode = 500
    RequestCapturingProtocol.stubbedBody = Data(String(repeating: "x", count: 5000).utf8)

    let error = try await expectThrows("HTTP 500") { try await sendRewrite() }
    guard case .http(_, let body)? = error as? ServiceError else {
        throw Failure(description: "expected ServiceError.http, got \(error)")
    }
    try expect(body.count < 700, "error bodies must not bloat the alert that surfaces them, got \(body.count) chars")
}

print("\nPromptLibrary")

await run.test("known preset text resolves to its title") {
    let preset = try unwrap(PromptLibrary.presets.first, "first preset")
    try expectEqual(PromptLibrary.title(for: preset.text), preset.title, "title")
    try expectEqual(PromptLibrary.presetID(for: preset.text), preset.id, "preset id")
}

await run.test("surrounding whitespace still matches a preset") {
    let preset = try unwrap(PromptLibrary.presets.first, "first preset")
    try expectEqual(PromptLibrary.title(for: "  \n\(preset.text)  "), preset.title, "title")
}

await run.test("unknown instruction falls back to the custom preset") {
    try expectEqual(PromptLibrary.title(for: "something bespoke"), "Custom", "title")
    try expectEqual(PromptLibrary.presetID(for: "something bespoke"), PromptLibrary.customPresetID, "preset id")
}

print("\nTextSelection")

await run.test("browser bundle identifiers are recognised") {
    try expect(TextSelection.isBrowserBundleIdentifier("com.apple.Safari"), "Safari is a browser")
    try expect(TextSelection.isBrowserBundleIdentifier("org.mozilla.firefox"), "Firefox is a browser")
    try expect(TextSelection.isBrowserBundleIdentifier("com.apple.TextEdit") == false, "TextEdit is not a browser")
    try expect(TextSelection.isBrowserBundleIdentifier(nil) == false, "nil is not a browser")
}

await run.test("browsers and range-less selections require verified paste replacement") {
    let browser = TextSelection(
        text: "Test",
        frame: nil,
        element: nil,
        selectedRange: CFRange(location: 0, length: 4),
        sourceBundleIdentifier: "com.apple.Safari"
    )
    try expect(browser.requiresVerifiedPasteReplacement, "browsers always need verified paste")

    let nativeWithRange = TextSelection(
        text: "Test",
        frame: nil,
        element: nil,
        selectedRange: CFRange(location: 0, length: 4),
        sourceBundleIdentifier: "com.apple.TextEdit"
    )
    try expect(nativeWithRange.requiresVerifiedPasteReplacement == false, "native field with a range does not")

    let nativeWithoutRange = TextSelection(
        text: "Test",
        frame: nil,
        element: nil,
        selectedRange: nil,
        sourceBundleIdentifier: "com.apple.TextEdit"
    )
    try expect(nativeWithoutRange.requiresVerifiedPasteReplacement, "missing range needs verified paste")
}

run.summarize()
