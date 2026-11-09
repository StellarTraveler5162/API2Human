import XCTest
@testable import API2Human

/// 提示词相关的纯文本处理：隐藏推演、交叉核对判定、资料拼装
final class InterviewPromptTests: XCTestCase {
    // MARK: stripTrace

    func testStripTraceRemovesCompleteBlock() {
        XCTAssertEqual(InterviewPrompt.stripTrace("<trace>\n1. x\n</trace>\n\n**大概在做什么**：a"), "**大概在做什么**：a")
    }

    func testStripTraceHidesHalfReceivedBlock() {
        XCTAssertEqual(InterviewPrompt.stripTrace("<trace>\n1. 推演到一半"), "")
    }

    func testStripTraceLeavesPlainText() {
        XCTAssertEqual(InterviewPrompt.stripTrace("普通回答"), "普通回答")
    }

    // MARK: reportsNoIssue（只看第一句）

    func testNoIssuePhrasings() {
        for text in ["没看到明显问题。可以优化：x",
                     "没看到明显的形状或 mask 方向错误，`tril` 加 `== 0` 的组合挡住了未来",
                     "整体逻辑是自洽的，没看到明显功能错误",
                     "逻辑上没看到明显错误，mask、缩放、拼头都对",
                     "**没有明显问题**"] {
            XCTAssertTrue(InterviewPrompt.reportsNoIssue(text), text)
        }
    }

    func testIssuePhrasings() {
        for text in ["mask 方向反了。`self.mask` 是 `tril(ones)`",
                     "排序方向反了，取到的是频率最低的 k 个",
                     "`masked_fill` 这一行屏蔽反了"] {
            XCTAssertFalse(InterviewPrompt.reportsNoIssue(text), text)
        }
    }

    // MARK: issueSection / crossCheckNote

    private let withBug = "**大概在做什么**：x\n**发现的问题**：mask 方向反了。\n**在项目里的作用**：y"
    private let clean = "**大概在做什么**：x\n**发现的问题**：没看到明显问题。\n**在项目里的作用**：y"

    func testIssueSectionExtractsMiddlePart() {
        XCTAssertEqual(InterviewPrompt.issueSection(withBug), "mask 方向反了。")
    }

    func testCrossCheckAgreementIsSilent() {
        XCTAssertNil(InterviewPrompt.crossCheckNote(shown: withBug, other: withBug))
        XCTAssertNil(InterviewPrompt.crossCheckNote(shown: clean, other: clean))
    }

    func testCrossCheckShownCleanOtherFoundBug() throws {
        let note = try XCTUnwrap(InterviewPrompt.crossCheckNote(shown: clean, other: withBug))
        XCTAssertTrue(note.contains("另一次分析发现了问题"))
        XCTAssertTrue(note.contains("mask 方向反了"))
    }

    func testCrossCheckShownBugOtherClean() throws {
        let note = try XCTUnwrap(InterviewPrompt.crossCheckNote(shown: withBug, other: clean))
        XCTAssertTrue(note.contains("另一次分析没发现"))
    }

    func testCrossCheckWithoutSectionsIsSilent() {
        XCTAssertNil(InterviewPrompt.crossCheckNote(shown: "这是一道题的解答", other: withBug))
    }

    // MARK: system prompt

    func testSystemPromptWithoutContextAsksForPlaceholders() {
        let prompt = InterviewPrompt.system(context: InterviewContext())
        XCTAssertTrue(prompt.contains("方括号占位"))
        XCTAssertFalse(prompt.contains("<我的简历>"))
    }

    func testSystemPromptFiltersMarkedClauses() {
        var ctx = InterviewContext()
        ctx.resume = "- 我的角色：负责核心链路；团队人数 [待确认]"
        let prompt = InterviewPrompt.system(context: ctx)
        XCTAssertTrue(prompt.contains("负责核心链路"))
        XCTAssertFalse(prompt.contains("待确认"))
    }

    func testLegacyProfileUsedWhenResumeEmpty() {
        XCTAssertTrue(InterviewPrompt.system(context: InterviewContext(), legacyProfile: "做过 iOS").contains("做过 iOS"))
    }
}

final class HistoryTextTests: XCTestCase {
    func testForHistoryStripsTraceAndTruncationNote() {
        let raw = "<trace>推演</trace>\n**发现的问题**：mask 反了" + AnthropicMessagesProvider.truncatedNote
        XCTAssertEqual(InterviewPrompt.forHistory(raw), "**发现的问题**：mask 反了")
    }
}
