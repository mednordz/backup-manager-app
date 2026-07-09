import ServiceManagement

/// Thin wrapper around SMAppService for the "open at login" toggle.
/// The user opts in/out explicitly via the menu bar item; nothing is
/// registered automatically on first launch.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
