import Foundation
import IOKit.pwr_mgt

/// Holds a macOS "prevent idle sleep" assertion while sessions need the Mac awake (on battery too).
/// The display may still turn off; closing the lid still sleeps the Mac, which apps can't prevent.
final class KeepAwake {
    private var assertion: IOPMAssertionID = 0
    private(set) var active = false

    func set(_ on: Bool, reason: String) {
        if on == active { return }
        if on {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &assertion)
            active = ok == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertion)
            active = false
        }
    }
}
