import Foundation

/// 面试场景的提示词。目标：首字快、能直接照着念、扛得住语音识别的错字。
enum InterviewPrompt {
    /// - context: 面试资料窗口里填的简历 / JD / 补充信息
    /// - legacyProfile: 旧版 llm.json 里的 profile 字段（简历栏为空时当简历用）
    static func system(context: InterviewContext, legacyProfile: String? = nil) -> String {
        var prompt = """
        你是我在线上面试中的实时提词助手。我会把面试官刚说的话（来自语音识别）发给你，你给出我可以直接说出口的回答。

        规则：
        1. 用第一人称、口语化，像我本人在回答；不要说"作为 AI"，不要复述问题，不要客套开场。
        2. 先给一句话结论，再给 2~4 个要点，每个要点一行、以"- "开头、不超过 40 字；关键词用 **加粗**。总长度控制在 200 字以内，追问细节时再展开。
        3. 面试官用英文问就用英文答，用中文问就用中文答（技术名词保留英文）。
        4. 文本来自语音识别，可能有同音错字、断句不准（如"三四握手"其实是"三次握手"、"rately motor"其实是"rate limiter"），按最合理的意思理解，不要指出识别错误。
        5. 行为面试题（冲突、失败、成就等）用 STAR 结构，给一个具体、可信的例子。
        6. 只有在这句话明显不需要我回应时，才只回复"（无需回答）"：寒暄和确认（"好的""嗯""能听到吗""我们开始吧"）、面试官介绍自己或公司、过渡语（"进入下一个环节"）、给我思考时间（"不着急""你可以先想一下""慢慢说"）、面试官自己在记录或操作（"稍等我记一下"）。任何提问、要求、追问——哪怕有错字、不完整、是半句话——都必须回答。
        7. 追问很短又缺少上下文时（如"你觉得呢""为什么"），结合前面的对话回答；前面的对话里找不到所指的内容时，不要编造话题，只给我一句可以直接说出口的澄清，比如"您是想听我对这个问题的看法，还是具体怎么做？"——不要说"没有上下文"。
        """
        var ctx = context
        if ctx.resume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let legacyProfile {
            ctx.resume = legacyProfile
        }
        func section(_ title: String, _ text: String) -> String? {
            // 任何来源的资料都按角色卡规则过滤：注释和带 [待确认]/[待补充] 的分句不给 AI
            let t = CandidateCard.forAI(text)
            guard !t.isEmpty else { return nil }
            return "<\(title)>\n\(String(t.prefix(InterviewContext.maxCharsPerField)))\n</\(title)>"
        }
        let sections = [section("我的简历", ctx.resume), section("目标岗位JD", ctx.jobDescription),
                        section("补充信息", ctx.notes)].compactMap { $0 }

        if sections.isEmpty {
            prompt += """

            8. 我还没有提供简历。需要具体经历、公司名、数字时，用方括号占位（如"[项目名]""[提升了 X%]"），让我自己替换，不要编造得像真的一样。
            """
        } else {
            prompt += """

            8. 下面是我面试前准备的资料（可能是 API2Human 面试者角色卡格式：「技能边界」里"了解或没用过"的技术被问到时要诚实说明，「红线」里的话题不要主动提、被问到按其中的说法回答）。回答必须和简历一致：项目、公司、职责、数字只能引用简历里有的，不能编造简历里没有的经历；简历里没有直接相关的经验时，就诚实地说，然后用最相关的经历或学习能力来补。
            9. 回答要往目标岗位 JD 的要求上靠，自然地用上 JD 里的关键词；补充信息里提到要突出或回避的点要照做，说"不展开细节"的就不要补充细节。
            10. 关于我个人的具体事实——数字、团队规模、薪资、时间、我项目里的具体设计和实现细节、我和谁合作做了什么——只能用资料里明确写了的，不能推断，也不能编。要区分两类问题："什么是分片键、一般怎么选"是技术题，可以正常回答；"你那个项目的分片键是怎么选的"问的是我的经历，资料里没写就绝不能说"我选了 SKU ID"。资料里没有时：
                - 第一行写"⚠️ 资料里没有：<缺的是什么>"，让我知道这部分要自己判断；
                - 接着给我一句诚实、可以直接说出口的话（如"这块细节我记得不太准，我说一下当时的思路"）；
                - 再给通用的做法要点，用"一般会……""可以……"的口吻，不要用第一人称说成是我做过的；
                - 薪资资料里没有具体数字时，只给不报数字的回应方式，绝不编数字。

            """ + sections.joined(separator: "\n\n")
        }
        return prompt
    }

    /// 送给模型的用户消息：带上"这是面试官说的"语境
    static func userMessage(question: String) -> String {
        "面试官：\(question)"
    }

    /// 正式回答前先输出 <trace>…</trace> 逐行推演（界面上隐藏）。A2H_TRACE=0 关闭，用于对比实验
    static var traceEnabled: Bool { ProcessInfo.processInfo.environment["A2H_TRACE"] != "0" }
    static let traceInstruction = """
    先在 <trace> 和 </trace> 之间写逐行推演：每行代码一条，写它**实际**做了什么（具体到值、形状、哪些位置被改），用极简短语，不超过 120 字；推演完再对比"想实现的功能"和"实际效果"。凡是 mask、条件判断、下标切片、比较运算（== / != / < / ~ / not），都要结合检索结果里的成员定义，写出具体是哪些位置为 True 或 1（例如 `torch.tril(ones)` 是下三角含对角线为 1，也就是"过去和自己"），再推出这一行实际屏蔽、保留或选中了谁；**不要相信注释和命名**，注释可能写错或者和代码不一致，一律以代码为准。这部分我看不到，只用来帮你想清楚。</trace> 之后再写正式回答。

    """

    // MARK: - 交叉核对（同一段代码问两次，比较"发现的问题"）

    /// 取出"发现的问题"那一段（到"在项目里的作用"为止）
    static func issueSection(_ text: String) -> String? {
        guard let start = text.range(of: "发现的问题") else { return nil }
        var body = text[start.upperBound...]
        if let end = body.range(of: "在项目里的作用") { body = body[..<end.lowerBound] }
        return String(body)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*：: \n#"))
            .replacingOccurrences(of: #"\n?\*\*\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 这一段的结论是不是"没问题"：只看开头第一句（后面常跟"可以优化"）。
    /// 模型的说法很多："没看到明显的形状或 mask 方向错误""整体逻辑是自洽的，没看到明显功能错误"……
    static func reportsNoIssue(_ section: String) -> Bool {
        let head = String(section.replacingOccurrences(of: "*", with: "").drop(while: { " -：:\n".contains($0) }).prefix(80))
        let patterns = [
            #"(没|未)(看到|发现|有|找到)[^。；;\n]{0,14}(问题|错误|bug|毛病|缺陷)"#,
            #"(逻辑|实现|代码|整体)[^。；;\n]{0,8}(是)?(正确|没问题|自洽|对的|没错)"#,
            #"^(无|暂无)明显问题"#,
        ]
        return patterns.contains { head.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// 两次结论不一致时，附在回答后面的提醒；一致返回 nil
    static func crossCheckNote(shown: String, other: String) -> String? {
        guard let a = issueSection(shown), let b = issueSection(other) else { return nil }
        switch (reportsNoIssue(a), reportsNoIssue(b)) {
        case (true, false):
            return "\n\n---\n⚠️ **交叉核对不一致**：另一次分析发现了问题，建议自己核对：\n" + b
        case (false, true):
            return "\n\n---\n⚠️ **交叉核对不一致**：另一次分析没发现上面的问题，建议自己核对。"
        default:
            return nil
        }
    }

    /// 写进对话历史 / 参与交叉核对的文本：去掉隐藏推演和"被截断"提示（它们不是模型的回答内容）
    static func forHistory(_ text: String) -> String {
        stripTrace(text).replacingOccurrences(of: AnthropicMessagesProvider.truncatedNote, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 界面显示时去掉 <trace>…</trace>（流式过程中只收到一半时也隐藏）
    static func stripTrace(_ text: String) -> String {
        guard let open = text.range(of: "<trace>") else { return text }
        guard let close = text.range(of: "</trace>", range: open.upperBound..<text.endIndex) else {
            return String(text[..<open.lowerBound])
        }
        return (String(text[..<open.lowerBound]) + String(text[close.upperBound...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 即圈即搜：屏幕上圈出的内容（OCR 文字）+ 面试官最近说的话 + 本地项目检索结果
    static func screenMessage(ocr: String, speech: String, project: String? = nil) -> String {
        var message = """
        我圈出了屏幕上的一块内容（通常是代码或题目）。下面是本机 OCR 识别出的文字，缩进丢失、个别字符可能识别错，按最合理的意思理解：
        ```
        \(ocr)
        ```
        """
        if let project {
            message += "\n\n在我的本地项目目录里检索到这段代码（这是真实检索结果，不是推测）：\n\(project)"
        } else {
            message += "\n\n（没有在本地项目目录里找到这段代码。）"
        }
        if !speech.isEmpty {
            message += "\n\n对方刚才说：\(speech)"
        }
        message += """

        请帮我理解它。\(traceEnabled ? traceInstruction : "")如果是代码，分三段，每段用加粗小标题开头：
        **大概在做什么**：一句话说清它的功能，再用 2~3 个要点按执行顺序讲关键步骤（输入、核心逻辑、输出）。按代码**实际执行的效果**讲，逐行推一遍，不要按函数名或注释猜它"应该"做什么。
        **发现的问题**：只写功能性错误（结果不对、会报错、和想实现的功能不一致）；性能、风格、可维护性不算问题，只能放在"可以优化的点"。实际效果和想实现的功能不一致的地方——在哪一行、为什么、怎么改，修改只给最关键的一处，用行内代码写出改后的那一行。只说确定的问题，拿不准的说"可能"；没有明显问题就说"没看到明显问题"，再给一个可以优化的点。
        **在项目里的作用**：只根据上面的检索结果说——它在哪个文件、属于哪个类/函数、被谁调用、在整个流程里负责哪一环。没有检索结果时，只说"没在项目目录里找到这段代码"，不要猜。

        如果是题目而不是代码：第一句给思路或答案，再给关键步骤，能给复杂度就给。
        其他要求：
        - 不要把疑似 OCR 识别错误的字符当成代码 bug（括号不配对、l/1/I、0/O/e、全角符号、拆成两行的标识符），回答里完全不要提识别的事。
        - 三段之间不能互相矛盾；不要用代码块，代码用行内 `code`。
        """
        return message
    }

    /// 面试官对上一题的补充：前面的问答已经在历史里，只回答补充的部分
    static func supplementMessage(_ text: String) -> String {
        "面试官补充：\(text)\n（接着上一题，只回答补充的部分，不要重复前面已经说过的内容）"
    }

    /// 模型判定不需要回答时的标记
    static let noAnswerMarker = "无需回答"
}
