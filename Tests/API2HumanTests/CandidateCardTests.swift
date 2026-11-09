import XCTest
@testable import API2Human

/// 角色卡（.a2hcard）解析与"面试 AI 看到的内容"过滤。规范：skills/api2human-candidate-card/references/a2hcard-spec.md
final class CandidateCardTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "a2hcard", subdirectory: "Fixtures"))
    }

    // MARK: 分句级过滤（规范第 3 节）

    func testUnconfirmedClauseIsDroppedButFactKept() {
        XCTAssertEqual(CandidateCard.forAI("- 我的角色：负责方案设计和核心派单链路；团队总人数 [待确认]"),
                       "- 我的角色：负责方案设计和核心派单链路")
    }

    func testCommaInsideBracketsDoesNotSplit() {
        XCTAssertEqual(CandidateCard.forAI("- 用过：Java [待确认]、Redis（GEO、二级缓存）"),
                       "- 用过：Redis（GEO、二级缓存）")
    }

    func testMarkerHintWithEnumerationCommaStaysOneClause() {
        XCTAssertEqual(CandidateCard.forAI("- 做法：拆分为 16 个分片；[待补充：分片键、迁移方案]"),
                       "- 做法：拆分为 16 个分片")
    }

    func testLineWithOnlyMarkerIsRemoved() {
        XCTAssertEqual(CandidateCard.forAI("- 学历：[待补充]\n- 城市：北京"), "- 城市：北京")
    }

    func testHeadingKeepsStructureAndOnlyDropsMarker() {
        XCTAssertEqual(CandidateCard.forAI("### 某公司 | 职位 | 2021 - 至今 [待确认]"), "### 某公司 | 职位 | 2021 - 至今")
    }

    func testCommentsAreRemoved() {
        XCTAssertEqual(CandidateCard.forAI("事实<!-- 来源：简历 -->\n<!--\n多行\n-->\n- 普通行"), "事实\n\n- 普通行")
    }

    func testLineWithoutMarkersIsUntouched() {
        let line = "- 做法：按城市分片，每个城市一个内存调度队列；派单结果批量写库"
        XCTAssertEqual(CandidateCard.forAI(line), line)
    }

    // MARK: 解析与映射

    func testParseMetaAndSections() throws {
        let card = try CandidateCard(text: String(contentsOf: fixture("example-zhangsan"), encoding: .utf8))
        XCTAssertEqual(card.version, 1)
        XCTAssertEqual(card.meta["name"], "张三")
        XCTAssertNotNil(card.sections[.projects])
        XCTAssertNotNil(card.sections[.skills])
        XCTAssertNotNil(card.sections[.redLines])
    }

    func testEnglishSectionNamesAreAccepted() throws {
        let card = try CandidateCard(text: "---\na2hcard: 1\nname: A\nrole: B\n---\n## Pitch\nhi\n## red lines\nno")
        XCTAssertEqual(card.sections[.pitch], "hi")
        XCTAssertEqual(card.sections[.redLines], "no")
    }

    func testRejectsFileWithoutHeader() {
        XCTAssertThrowsError(try CandidateCard(text: "## 一句话定位\nhi"))
        XCTAssertThrowsError(try CandidateCard(text: "---\nname: A\n---\n"), "缺少版本号")
        XCTAssertThrowsError(try CandidateCard(text: "---\na2hcard: 1\nname: A\n"), "头部没有结束")
    }

    func testMarkedMetaIsNotSentToAI() throws {
        let card = try CandidateCard(text: String(contentsOf: fixture("edge"), encoding: .utf8))
        XCTAssertFalse(card.interviewContext.resume.contains("工作年限"), "years 带 [待确认]，不应进入资料")
    }

    func testMappingToThreeFields() throws {
        let card = try CandidateCard(text: String(contentsOf: fixture("example-zhangsan"), encoding: .utf8))
        let ctx = card.interviewContext
        XCTAssertTrue(ctx.resume.contains("## 项目经历"))
        XCTAssertTrue(ctx.notes.contains("## 求职口径"))
        XCTAssertTrue(ctx.notes.contains("## 红线"))
        XCTAssertFalse(ctx.resume.contains("## 红线"))
        XCTAssertTrue(ctx.jobDescription.contains("美团"))
    }

    func testMarkerCountsIgnoreComments() {
        let counts = CandidateCard.markerCounts("a [待确认] b [待确认：原因] c [待补充：x]\n<!-- [待确认] -->")
        XCTAssertEqual(counts.unconfirmed, 2)
        XCTAssertEqual(counts.missing, 1)
    }

    // MARK: 与 Python 校验脚本的一致性（两端必须同步修改）

    func testSwiftAndPythonAIViewsMatch() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/api2human-candidate-card/scripts/validate_a2hcard.py")
        for name in ["example-zhangsan", "edge", "tricky"] {
            let url = try fixture(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", script.path, url.path, "--ai-view"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let python = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let swift = CandidateCard.forAI(try String(contentsOf: url, encoding: .utf8))
            func compact(_ s: String) -> [String] { s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
            XCTAssertEqual(compact(swift), compact(python), "\(name) 的 Swift / Python AI 视图不一致")
        }
    }
}

/// 项目规则：Swift 的过滤和 validate_a2hcard.py 的 ai_view 必须一致。这里直接跑 Python 逐字节对比。
final class CandidateCardParityTests: XCTestCase {
    private func pythonAIView(_ text: String) throws -> String {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("skills/api2human-candidate-card/scripts/validate_a2hcard.py")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-parity-\(UUID()).a2hcard")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script.path, file.path, "--ai-view"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func testForAIFileMatchesPythonOnFixturesAndVariants() throws {
        var cases: [(String, String)] = []
        for name in ["example-zhangsan", "edge", "tricky"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "a2hcard", subdirectory: "Fixtures"))
            let text = try String(contentsOf: url, encoding: .utf8)
            cases.append((name, text))
            cases.append((name + "+CRLF", text.replacingOccurrences(of: "\n", with: "\r\n")))
            cases.append((name + "+BOM", "\u{FEFF}" + text))
        }
        cases.append(("variation-selector", "---\na2hcard: 1\nname: A\nrole: B\n---\n## Pitch\n- x：keep。\u{FE0F}[待确认]，d\n- y：a，\u{0301}b [待补充]\n"))
        cases.append(("lone-CR", "---\na2hcard: 1\nname: A\nrole: B\n---\r## Pitch\rfoo\rbar [待确认]，x\r"))
        cases.append(("double-BOM", "\u{FEFF}\u{FEFF}---\na2hcard: 1\nname: A\nrole: B\n---\n## Pitch\nhi\n"))
        cases.append(("meta-marker", "---\nname: 张三\nrole: 后端，资深 [待确认]\nyears: 6年\n---\n\n## 技能边界\n- 熟练：Go、Kafka [待确认]\n"))
        for (name, text) in cases {
            let py = try pythonAIView(text)
            XCTAssertFalse(py.isEmpty, "\(name)：Python 没有输出")
            XCTAssertEqual(CandidateCard.forAIFile(text), py, name)
        }
    }

    func testHeadingRulesMatchPython() throws {
        let card = try CandidateCard(text: "---\na2hcard: 1\nname: A\nrole: B\n---\n##\tPitch\nhi\n## \n不是标题\n")
        XCTAssertTrue(card.interviewContext.resume.contains("hi"))
        XCTAssertTrue(card.interviewContext.resume.contains("不是标题"), "空标题不算章节，内容归入上一章")
    }

    /// 注释掉的整段（含 ## 标题）不能发给 AI：注释要在切章节之前去掉
    func testCommentedOutSectionNeverReachesAI() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "commented", withExtension: "a2hcard", subdirectory: "Fixtures"))
        let card = try CandidateCard(text: String(contentsOf: url, encoding: .utf8))
        let ctx = card.interviewContext
        let all = [ctx.resume, ctx.jobDescription, ctx.notes].joined(separator: "\n")
        XCTAssertFalse(all.contains("机密"), all)
        XCTAssertFalse(all.contains("<!--"), all)
        XCTAssertFalse(all.contains("-->"), all)
        XCTAssertTrue(all.contains("新项目"))
    }

    func testUnclosedMarkerInMetaIsHidden() throws {
        let c = try CandidateCard(text: "---\na2hcard: 1\nname: A\nrole: B\nyears: 6 [待确认\n---\n## Pitch\nx\n")
        XCTAssertFalse(c.interviewContext.resume.contains("工作年限"), c.interviewContext.resume)
    }

    func testYearsSuffixNotDoubled() throws {
        let card = try CandidateCard(text: "---\na2hcard: 1\nname: 张三\nrole: 后端\nyears: 6年\n---\n## Pitch\n后端\n")
        XCTAssertTrue(card.interviewContext.resume.contains("工作年限：6年"))
        XCTAssertFalse(card.interviewContext.resume.contains("6年 年"))
        for (raw, shown) in [("6", "6 年"), ("6.5", "6.5 年"), ("6+", "6+ 年"), ("6 years", "6 years"), ("6年+", "6年+")] {
            let c = try CandidateCard(text: "---\na2hcard: 1\nname: A\nrole: B\nyears: \(raw)\n---\n## Pitch\nx\n")
            XCTAssertTrue(c.interviewContext.resume.contains("工作年限：\(shown)"), raw)
            XCTAssertFalse(c.interviewContext.resume.contains("\(shown) 年"), raw)
        }
    }
}
