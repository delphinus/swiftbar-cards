// swift-tools-version:5.9
// プラグインは SwiftPM を通さず、scripts/lib.sh の build_helper が swiftc で直接
// ビルドする。このファイルはエディタの補完と `swift build` での確認のために置く。
import PackageDescription

let package = Package(
    name: "swiftbar-cards",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared"),
        .executableTarget(name: "nowplaying", dependencies: ["Shared"]),
        .executableTarget(name: "sysmon", dependencies: ["Shared"]),
        .executableTarget(name: "weather-card", dependencies: ["Shared"]),
    ]
)
