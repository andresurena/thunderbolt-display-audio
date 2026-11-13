import Foundation
import ServiceManagement

/// "Open at Login", whichever way it was set up: the LaunchAgent written by scripts/install.sh,
/// or the system login item list (SMAppService) for a downloaded copy. Never both.
enum LoginItem {
    static let agentLabel = "com.andresurena.ThunderboltDisplays.helper"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var installedByScript: Bool { FileManager.default.fileExists(atPath: agentURL.path) }

    static var isOn: Bool { installedByScript || SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on {
            guard !isOn else { return }
            try SMAppService.mainApp.register()
        } else {
            // Removing the file is enough: launchd keeps this session's copy running, but has nothing
            // to load at the next login.
            if installedByScript { try FileManager.default.removeItem(at: agentURL) }
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}
