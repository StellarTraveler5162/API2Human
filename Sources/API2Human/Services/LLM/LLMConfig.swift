import Foundation

/// LLM 接入配置。密钥不进代码仓库：读 ~/Library/Application Support/API2Human/llm.json，
/// 字段缺失时再看环境变量（ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / API2HUMAN_MODEL）。
///
/// llm.json 示例：
/// {
///   "baseURL": "https://api.deepseek.com/anthropic",   // DeepSeek 官方的 Anthropic 兼容接口
///   "authToken": "sk-...",
///   "model": "deepseek-flash",                         // DeepSeek-V4.1-Flash
///   "thinking": false,
///   "screenModel": "deepseek-v4-pro",                  // 即圈即搜用的模型（读代码要更强的模型）
///   "screenCheckModel": "deepseek-flash",              // 即圈即搜第二路交叉核对：换模型 + 打开思考
///   "screenCheckThinking": true,
///   "maxTokens": 800,
///   "profile": "我是 5 年 iOS 开发，熟悉 Swift / SwiftUI，上一家公司在做……"
/// }
struct LLMConfig: Codable, Sendable {
    var baseURL: String
    var authToken: String
    var model: String
    var maxTokens: Int?
    /// 可选：我的背景（简历要点 / 目标岗位），拼进 system prompt，让回答更像"我"
    var profile: String?
    /// 是否让模型先"思考"再回答。默认关：DeepSeek-V4.1-Flash 实测首字 1.6s -> 0.75s，质量差不多
    var thinking: Bool?
    /// 即圈即搜（屏幕代码 / 题目）用的模型。实测找代码 bug：deepseek-flash 4 次全错，deepseek-v4-pro 不思考 2/2 正确、首字 0.8s
    var screenModel: String?
    /// 即圈即搜的第二路（交叉核对）用的模型和是否思考：和第一路"想法不一样"才能互相纠错
    var screenCheckModel: String?
    var screenCheckThinking: Bool?
    /// 备用接口：主接口重试一次仍失败（429 / 5xx / 网络错误 / 12 秒不出字）时改用它。没写的字段沿用主接口
    var fallback: Fallback?

    struct Fallback: Codable, Sendable {
        var baseURL: String?
        var authToken: String?
        var model: String?
        var thinking: Bool?
    }

    /// 备用接口的完整配置；没配置备用、或备用和主接口完全一样时为 nil
    var fallbackConfig: LLMConfig? {
        guard let fb = fallback else { return nil }
        var c = self
        c.baseURL = Self.nonEmpty(fb.baseURL) ?? baseURL
        // 主接口的 Key 只沿用到同一个服务器：备用换了地址又没填 Key，不能把主 Key 发给别家
        // 协议、主机、端口都相同才算同一个服务器（http://同域名 会把 Key 明文发出去）
        func origin(_ s: String) -> String? {
            guard let u = URL(string: s), let host = u.host?.lowercased() else { return nil }
            let scheme = u.scheme?.lowercased() ?? ""
            return "\(scheme)://\(host):\(u.port ?? (scheme == "http" ? 80 : 443))"
        }
        let sameHost = origin(c.baseURL) != nil && origin(c.baseURL) == origin(baseURL)
        guard let token = Self.nonEmpty(fb.authToken) ?? (sameHost ? authToken : nil) else {
            Log.info("备用接口 \(c.baseURL) 没有配置 authToken，已忽略备用")
            return nil
        }
        c.authToken = token
        c.model = Self.nonEmpty(fb.model) ?? model
        c.thinking = fb.thinking ?? thinking
        c.fallback = nil
        guard c.baseURL != baseURL || c.model != model || c.authToken != authToken else { return nil }
        return c
    }

    static var fileURL: URL {
        // 调试：A2H_LLM_JSON=/path/other.json 换一份配置对比模型，不动正式的 llm.json
        if let p = ProcessInfo.processInfo.environment["A2H_LLM_JSON"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return AudioCaptureManager.recordingsRoot.deletingLastPathComponent().appendingPathComponent("llm.json")
    }

    static func load() throws -> LLMConfig {
        let env = ProcessInfo.processInfo.environment
        var config: FileConfig?
        if let data = try? Data(contentsOf: fileURL) {
            do {
                config = try JSONDecoder().decode(FileConfig.self, from: data)
            } catch {
                throw LLMError.config("llm.json 格式不对：\(error.localizedDescription)")
            }
        }
        let baseURL = nonEmpty(config?.baseURL) ?? nonEmpty(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com"
        guard let token = nonEmpty(config?.authToken) ?? nonEmpty(env["ANTHROPIC_AUTH_TOKEN"]) ?? nonEmpty(env["ANTHROPIC_API_KEY"]) else {
            throw LLMError.config("没有配置 API Key，请编辑 \(fileURL.path)")
        }
        guard let model = nonEmpty(config?.model) ?? nonEmpty(env["API2HUMAN_MODEL"]) else {
            throw LLMError.config("没有配置模型名（llm.json 的 model 字段）")
        }
        return LLMConfig(baseURL: baseURL, authToken: token, model: model,
                         maxTokens: config?.maxTokens, profile: nonEmpty(config?.profile),
                         thinking: config?.thinking, screenModel: nonEmpty(config?.screenModel),
                         screenCheckModel: nonEmpty(env["A2H_CHECK_MODEL"]) ?? nonEmpty(config?.screenCheckModel),
                         screenCheckThinking: env["A2H_CHECK_THINKING"].map { $0 == "1" } ?? config?.screenCheckThinking,
                         fallback: config?.fallback)
    }

    /// llm.json 的读入形态：三个必需字段都可以不写（从环境变量补），所以单独一个全可选的类型
    private struct FileConfig: Decodable {
        var baseURL: String?
        var authToken: String?
        var model: String?
        var maxTokens: Int?
        var profile: String?
        var thinking: Bool?
        var screenModel: String?
        var screenCheckModel: String?
        var screenCheckThinking: Bool?
        var fallback: Fallback?
    }

    /// `https://host` / `https://host/` / `https://host/v1` 都拼成 `https://host/v1/messages`
    var messagesURL: URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/v1/messages")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

enum LLMError: LocalizedError {
    case config(String)
    case http(Int, String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .config(let msg): msg
        case .http(let code, let body): "LLM 请求失败（HTTP \(code)）：\(body)"
        case .api(let msg): "LLM 返回错误：\(msg)"
        }
    }
}
