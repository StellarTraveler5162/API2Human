// 用 macOS 自带的 PDFKit 把 PDF 转成纯文本，不需要安装任何工具。
// 用法：swift pdf2txt.swift 简历.pdf
import PDFKit
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("用法：swift pdf2txt.swift <文件.pdf>\n".data(using: .utf8)!)
    exit(2)
}
guard let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write("打不开 PDF\n".data(using: .utf8)!)
    exit(1)
}
let text = doc.string ?? ""
if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    FileHandle.standardError.write("这个 PDF 没有文字层（可能是扫描件），需要 OCR\n".data(using: .utf8)!)
    exit(1)
}
print(text)
