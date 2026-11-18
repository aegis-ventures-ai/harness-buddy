import Observation
import ServiceManagement

/// "Open at login", backed by the system's login items (`SMAppService.mainApp`). The system is
/// the source of truth: the user can also turn it off in System Settings → General → Login Items,
/// so nothing is stored by the app.
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var error: String?

    var isEnabled: Bool { status == .enabled }
    /// Registered, but the user has to allow it in System Settings first.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = enabled
                ? "Couldn't add Harness Butler to your login items: \(error.localizedDescription)"
                : "Couldn't remove Harness Butler from your login items: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
