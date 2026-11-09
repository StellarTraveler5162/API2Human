// swift-tools-version: 6.0
import PackageDescription
import Foundation

/// 测试运行时要能找到 sherpa-onnx 动态库
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "API2Human",
    platforms: [.macOS("14.2")],  // Core Audio Process Tap 需要 14.2+
    products: [
        .executable(name: "API2Human", targets: ["API2Human"])
    ],
    targets: [
        // sherpa-onnx C API（小米 新一代 Kaldi），预编译 dylib 放在 Vendor/sherpa-onnx/lib
        .systemLibrary(name: "CSherpaOnnx", path: "Vendor/sherpa-onnx"),
        .executableTarget(
            name: "API2Human",
            dependencies: ["CSherpaOnnx"],
            path: "Sources/API2Human",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/sherpa-onnx/lib",
                    // .app 内：Contents/Frameworks；swift run 时：直接用 Vendor 目录
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../Vendor/sherpa-onnx/lib",
                ])
            ]
        ),
        // 纯逻辑单元测试：角色卡过滤、交叉核对判定、项目检索与 OCR 校正、配置解析等
        .testTarget(
            name: "API2HumanTests",
            dependencies: ["API2Human"],
            path: "Tests/API2HumanTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .unsafeFlags([
                    "-LVendor/sherpa-onnx/lib",
                    "-Xlinker", "-rpath", "-Xlinker", packageRoot + "/Vendor/sherpa-onnx/lib",
                ])
            ]
        ),
    ]
)
