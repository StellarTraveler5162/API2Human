import XCTest
@testable import API2Human

/// 项目代码检索：定位、调用链、用源文件校正 OCR
final class ProjectCodeSearchTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/proj")

    private func file(_ name: String, _ text: String) -> ProjectCodeSearch.SourceFile {
        .init(root: root, url: root.appendingPathComponent(name), lines: text.components(separatedBy: "\n"))
    }

    private lazy var model = file("model.py", """
    class Attn(nn.Module):
        def __init__(self, n):
            self.register_buffer("mask", torch.tril(torch.ones(n, n)))
        def forward(self, x):
            scores = self.q(x) @ self.k(x).transpose(-2, -1)
            scores = scores.masked_fill(self.mask == 0, float('-inf'))  # 人话：挡住未来
            self.last = scores.detach().cpu()
            return scores.softmax(dim=-1)
    class Block(nn.Module):
        def __init__(self, n):
            self.attn = Attn(n)
    """)

    private lazy var train = file("train.py", "def main():\n    blk = Block(8)\n")

    /// 从磁盘读：CRLF 文件不留 \r；根目录名在路径中间再出现时，相对路径只去掉开头那一段
    func testLoadFilesStripsCRAndKeepsRelativePath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-\(UUID().uuidString)")
        let root = base.appendingPathComponent("proj")
        let nested = root.appendingPathComponent("proj/sub")       // 路径里第二次出现 proj
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "def f():\r\n    return 1\r\n".write(to: nested.appendingPathComponent("a.py"), atomically: true, encoding: .utf8)
        let files = ProjectCodeSearch.loadFiles(in: [root])
        let f = try XCTUnwrap(files.first { $0.url.lastPathComponent == "a.py" })
        XCTAssertFalse(f.lines.contains { $0.hasSuffix("\r") }, "\(f.lines)")
        XCTAssertEqual(f.relativePath, "proj/proj/sub/a.py")
    }

    func testLocateFindsFileLinesAndEnclosingSymbols() throws {
        let ocr = "scores = self.q(x) @ self.k(x).transpose(-2, -1)\nscores = scores.masked_fill(self.mask == 0, float('-inf'))"
        let loc = try XCTUnwrap(ProjectCodeSearch.locate(ocr: ocr, files: [train, model]))
        XCTAssertEqual(loc.file.url.lastPathComponent, "model.py")
        XCTAssertEqual(loc.firstLine, 4)
        XCTAssertEqual(loc.symbols, ["Attn", "forward"])
    }

    func testLocateToleratesOCRConfusions() throws {
        // OCR 常见错误：fill→fil1、0→O、.→-、全角括号
        let ocr = "scores = scores.masked_fil1（self.mask == O, float（'-inf'））\nself.last = scores.detach()-cpu()"
        XCTAssertNotNil(ProjectCodeSearch.locate(ocr: ocr, files: [model]))
    }

    func testLocateReturnsNilForUnrelatedCode() {
        XCTAssertNil(ProjectCodeSearch.locate(ocr: "def something_else(a, b):\n    return a + b + c * d", files: [model, train]))
    }

    func testCorrectionRestoresOCRArtifactsFromSource() throws {
        let ocr = "scores = scores.masked_fil1（self.mask == O, float（'-inf'））# 人话：挡住\nself.last = scores.detach()-cpu()"
        let loc = try XCTUnwrap(ProjectCodeSearch.locate(ocr: ocr, files: [model]))
        let fixed = ProjectCodeSearch.correctOCR(ocr, file: model, near: loc)
        XCTAssertEqual(fixed.replaced, 2)
        XCTAssertTrue(fixed.text.contains("masked_fill(self.mask == 0, float('-inf'))"))
        XCTAssertTrue(fixed.text.contains("scores.detach().cpu()"))
    }

    func testCorrectionKeepsRealEdit() throws {
        // 屏幕上把 == 0 改成了 == 1：这是真实改动，不能被"校正"回去
        let ocr = "scores = self.q(x) @ self.k(x).transpose(-2, -1)\nscores = scores.masked_fill(self.mask == 1, float('-inf'))"
        let loc = try XCTUnwrap(ProjectCodeSearch.locate(ocr: ocr, files: [model]))
        let fixed = ProjectCodeSearch.correctOCR(ocr, file: model, near: loc)
        XCTAssertTrue(fixed.text.contains("== 1"))
        XCTAssertFalse(fixed.text.contains("== 0"))
    }

    func testReferencesSkipDefinitionAndComments() {
        let refs = ProjectCodeSearch.references(of: "Block", files: [model, train, file("x.py", "# Block 只是注释")])
        XCTAssertEqual(refs.map { $0.file.url.lastPathComponent }, ["train.py"])
        XCTAssertEqual(refs.first?.enclosing, ["main"])
    }

    func testHalfWidth() {
        XCTAssertEqual(ProjectCodeSearch.halfWidth("f（x，y）：［1］"), "f(x,y):[1]")
    }
}

final class ProjectCodeSearchPerformanceTests: XCTestCase {
    /// 300 个文件 × 300 行：一次完整检索（定位 + 两层调用链 + 成员定义）应在 1 秒内
    func testSearchIsFastOnMediumProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2h-perf-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for f in 0..<300 {
            var lines: [String] = []
            for c in 0..<10 {
                lines.append("class Module\(f)_\(c):")
                lines.append("    def __init__(self, n):")
                lines.append("        self.value_\(c) = torch.zeros(n, n)  # 初始化")
                for l in 0..<27 { lines.append("        x_\(l) = helper_\(l % 7)(self.value_\(c), \(l)) + Module\((f + 1) % 300)_\(c)(n)") }
            }
            try lines.joined(separator: "\n").write(to: root.appendingPathComponent("m\(f).py"), atomically: true, encoding: .utf8)
        }
        let ocr = "x_3 = helper_3(self.value_4, 3) + Module151_4(n)\nx_4 = helper_4(self.value_4, 4) + Module151_4(n)"
        setenv("A2H_PROJECT_DIRS", root.path, 1)
        defer { unsetenv("A2H_PROJECT_DIRS") }
        let started = Date()
        let result = ProjectCodeSearch.search(ocr: ocr)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertNotNil(result.context)
        XCTAssertLessThan(elapsed, 1.0, "检索用了 \(String(format: "%.2f", elapsed))s")
    }
}
