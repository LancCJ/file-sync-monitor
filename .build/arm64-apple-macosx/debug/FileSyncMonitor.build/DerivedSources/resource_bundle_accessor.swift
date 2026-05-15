import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("FileSyncMonitor_FileSyncMonitor.bundle").path
        let buildPath = "/Users/chenjian/Documents/codes/file-sync-monitor/.build/arm64-apple-macosx/debug/FileSyncMonitor_FileSyncMonitor.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            // Users can write a function called fatalError themselves, we should be resilient against that.
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}