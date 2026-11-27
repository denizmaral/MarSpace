import AppKit
import Common

@MainActor
var appForTests: (any AbstractApp)? = nil

@MainActor
private func focusedApp(_ cm: CancellationMode) async throws -> (any AbstractApp)? {
    if isUnitTest {
        return appForTests
    } else {
        check(appForTests == nil)
        return switch RunningApps.frontmost {
            case let frontmost?: try await MacApp.registerWithinDeadline(frontmost, cm)
            case nil: nil
        }
    }
}

@MainActor
func getNativeFocusedWindow(_ cm: CancellationMode) async throws -> Window? {
    try await focusedApp(cm)?.getFocusedWindow(cm)
}
