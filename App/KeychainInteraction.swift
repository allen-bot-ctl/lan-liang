import Foundation
import Security

/// The macOS file-based Keychain can ignore LAContext's no-UI preference
/// while locked. Temporarily veto Keychain UI process-wide for this synchronous
/// background operation; restore the prior setting before any interactive call.
enum KeychainInteraction {
    private static let lock = NSLock()

    static func perform(interactive: Bool, _ operation: () -> OSStatus) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        if interactive { return operation() }

        var previous = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess else {
            return errSecInteractionNotAllowed
        }
        if !previous.boolValue { return operation() }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            return errSecInteractionNotAllowed
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return operation()
    }
}
