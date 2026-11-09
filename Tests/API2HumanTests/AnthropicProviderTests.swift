import XCTest
@testable import API2Human

/// SSE 解析：用 URLProtocol 伪造服务端，不联网
final class AnthropicProviderTests: XCTestCase {
    final class FakeServer: URLProtocol {
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var body = ""

        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fake.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                           headerFields: ["content-type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() { URLProtocol.registerClass(FakeServer.self) }
    override func tearDown() { URLProtocol.unregisterClass(FakeServer.self) }

    private func event(_ json: String) -> String { "data: \(json)\n\n" }
    private let delta = { (t: String) in #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(t)"}}"# }

    private func collect() async throws -> String {
        let provider = AnthropicMessagesProvider(config: LLMConfig(baseURL: "https://fake.invalid", authToken: "t", model: "m"))
        var text = ""
        for try await chunk in provider.streamReply(system: "s", history: [ChatTurn(role: .user, content: "q")]) { text += chunk }
        return text
    }

    func testNormalStream() async throws {
        FakeServer.status = 200
        FakeServer.body = event(#"{"type":"message_start"}"#) + event(delta("你好")) + event(delta("，世界"))
            + event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"不显示"}}"#)
            + event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) + event(#"{"type":"message_stop"}"#)
        let text = try await collect()
        XCTAssertEqual(text, "你好，世界")
    }

    func testDroppedConnectionIsAnError() async {
        FakeServer.status = 200
        FakeServer.body = event(delta("半截"))            // 没有 message_stop
        do {
            _ = try await collect()
            XCTFail("连接中断应该报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("连接中断"))
        }
    }

    func testMaxTokensIsMarked() async throws {
        FakeServer.status = 200
        FakeServer.body = event(delta("很长")) + event(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#)
            + event(#"{"type":"message_stop"}"#)
        let text = try await collect()
        XCTAssertTrue(text.hasSuffix(AnthropicMessagesProvider.truncatedNote))
    }

    func testHTTPErrorMessage() async {
        FakeServer.status = 401
        FakeServer.body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        do {
            _ = try await collect()
            XCTFail("401 应该报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertTrue(error.localizedDescription.contains("invalid x-api-key"))
        }
    }

    func testErrorEventInStream() async {
        FakeServer.status = 200
        FakeServer.body = event(delta("a")) + event(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        do {
            _ = try await collect()
            XCTFail("流中的 error 事件应该报错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Overloaded"))
        }
    }
}
