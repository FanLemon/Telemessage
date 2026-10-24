import Cocoa
@testable import TelemessageCore

// Usage: swift run TelemessageSnapshots <output-dir> [name-filter]
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if arguments.count > 1 {
        Snapshot.outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try? FileManager.default.createDirectory(at: Snapshot.outputDirectory, withIntermediateDirectories: true)
    }
    let filter = arguments.count > 2 ? arguments[2] : ""

    NSApplication.shared.setActivationPolicy(.accessory)

    for (name, run) in Scenes.all where filter.isEmpty || name.contains(filter) {
        run()
    }
}
