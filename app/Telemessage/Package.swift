// swift-tools-version:6.2
import Foundation
import PackageDescription

// Builds the app's code outside Xcode for `swift test` and the snapshot renderer.
// TelemessageCore compiles the same files as the app target except App/ (the @main entry point).
// Swift settings mirror the app target's build settings so the code compiles identically.
let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// Native libraries collected by ../../build-libs.sh, at the path the Xcode build settings use.
let projectDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func vendorPath(_ relative: String) -> String {
    projectDir.appending(path: relative).standardizedFileURL.path
}
let libs = vendorPath("../../libs")

// Every target that (transitively) imports CTDJson needs TDLib's headers.
let nativeSettings = settings + [.unsafeFlags(["-Xcc", "-I\(libs)/include"])]

let tdlibLibraries = [
    "tdjson_static", "tdjson_private", "tdclient", "tdcore", "tdapi", "tdmtproto", "tdnet",
    "tddb", "tdsqlite", "tdactor", "tde2e", "tdutils", "ssl", "crypto", "z", "c++",
    "rlottie", "vpx",
]

let package = Package(
    name: "TelemessageCore",
    platforms: [.macOS("27.0")],
    targets: [
        .systemLibrary(name: "CTDJson", path: "Vendor/CTDJson"),
        .systemLibrary(name: "CRLottie", path: "Vendor/CRLottie"),
        .systemLibrary(name: "CVPX", path: "Vendor/CVPX"),
        .target(
            name: "TelemessageCore",
            dependencies: ["CTDJson", "CRLottie", "CVPX"],
            path: "Telemessage",
            // App-target-only files: the entry point, storyboard, assets and credentials.
            exclude: ["App", "Base.lproj", "Assets.xcassets", "TelegramSecrets.plist"],
            sources: ["Telegram", "Persistence", "Domain", "UI", "Media"],
            swiftSettings: nativeSettings,
            linkerSettings: [.unsafeFlags(["-L\(libs)/lib"])]
                + tdlibLibraries.map { .linkedLibrary($0) }
        ),
        .testTarget(
            name: "TelemessageTests",
            dependencies: ["TelemessageCore"],
            path: "TelemessageTests",
            resources: [.copy("Fixtures")],
            swiftSettings: nativeSettings
        ),
        // Renders windows with fixture data to PNGs: `swift run TelemessageSnapshots <output-dir>`.
        .executableTarget(
            name: "TelemessageSnapshots",
            dependencies: ["TelemessageCore"],
            path: "TelemessageSnapshots",
            swiftSettings: nativeSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
