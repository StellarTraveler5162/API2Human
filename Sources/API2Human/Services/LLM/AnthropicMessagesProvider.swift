import Foundation

/// Anthropic Messages API（/v1/messages, stream=true）客户端。
/// 兼容这个协议的网关（DeepSeek 等转发服务）也能直接用，只要换 baseURL 和 model。
struct AnthropicMessagesProvider: LLMProvider {
    let config: LLMConfig

    func streamReply(system: String, history: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, history: history) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(system: String, history: [ChatTurn], yield: (String) -> Void) async throws {
        guard let url = config.messagesURL else { throw LLMError.config("baseURL 无效：\(config.baseURL)") }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        // 官方接口认 x-api-key，各类网关多认 Bearer：两个都带
        request.setValue(config.authToken, forHTTPHeaderField: "x-api-key")
        request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "authorization")

        var body: [String: Any] = [
            "model": config.model,
            // 思考会先消耗大量 token，上限太小会一个字都没输出
            "max_tokens": config.thinking == true ? max(config.maxTokens ?? 0, 6000) : (config.maxTokens ?? 800),
            "stream": true,
            "system": system,
            "messages": history.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        if config.thinking != true {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var text = ""
            for try await line in bytes.lines {
                text += line
                if text.count > 600 { break }
            }
            throw LLMError.http(status, Self.errorMessage(from: text) ?? String(text.prefix(300)))
        }

        // SSE：只关心 data: 行；文本增量在 content_block_delta / text_delta 里。
        // 正常结束一定有 message_stop（DeepSeek / Anthropic 实测都会发）；没收到说明连接中途断了
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            switch type {
            case "content_block_delta":
                // thinking_delta 等非文本增量直接忽略
                if let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    yield(text)
                }
            case "error":
                let error = event["error"] as? [String: Any]
                throw LLMError.api(error?["message"] as? String ?? payload)
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "max_tokens" {
                    yield(Self.truncatedNote)
                }
            case "message_stop":
                return
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw LLMError.api("连接中断，回答可能不完整")
    }

    static let truncatedNote = "\n\n…（回答达到长度上限，被截断了）"

    private static func errorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any] { return error["message"] as? String }
        return json["message"] as? String
    }
}
