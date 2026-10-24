// swift-tools-version:5.9
import Foundation
import PackageDescription

// Static TDLib + OpenSSL collected into ../libs by ../build-libs.sh (the same libraries the app links).
let libsDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../libs")
    .standardizedFileURL.path

let tdlibLibraries = [
    "tdjson_static", "tdjson_private", "tdclient", "tdcore", "tdapi", "tdmtproto", "tdnet",
    "tddb", "tdsqlite", "tdactor", "tde2e", "tdutils", "ssl", "crypto", "z", "c++",
]

let package = Package(
    name: "tdcli",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CTDJson", path: "Sources/CTDJson"),
        .executableTarget(
            name: "tdcli",
            dependencies: ["CTDJson"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(libsDir)/include"]),
            ],
            linkerSettings: [.unsafeFlags(["-L\(libsDir)/lib"])] + tdlibLibraries.map { .linkedLibrary($0) }
        ),
    ]
)
