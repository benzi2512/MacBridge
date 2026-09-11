import SwiftUI

/// A single vocabulary for the widget and app. Only discrete UI changes
/// animate; no display link, repeating animation, or animation polling.
/// Response/damping values are referenced to CodeNotch 8406a27 (MIT); see
/// Observer/CODENOTCH-REFERENCE.md for the source and deliberate MB differences.
enum FloatingMotion {
    static let unfoldResponse = 0.42
    static let unfoldDamping = 0.78
    static let contentsResponse = 0.36
    static let contentsDamping = 0.82
    static let glideResponse = 0.50
    static let glideDamping = 0.86
    static let crossfadeDuration = 0.16
    static let staggerStep = 0.045
    static let maximumStagger = 0.18

    static func unfold(reduced: Bool) -> Animation? {
        reduced ? nil : .spring(response: unfoldResponse, dampingFraction: unfoldDamping)
    }

    static func panel(reduced: Bool) -> Animation {
        reduced ? .linear(duration: MBMetrics.reducedMotionDuration)
            : .spring(response: glideResponse, dampingFraction: glideDamping)
    }

    static func staggerDelay(index: Int) -> TimeInterval {
        min(Double(max(0, index)) * staggerStep, maximumStagger)
    }

    static func contents(index: Int, appearing: Bool, reduced: Bool) -> Animation {
        if reduced { return .linear(duration: MBMetrics.reducedMotionDuration) }
        if !appearing { return .easeIn(duration: 0.20) }
        return .spring(response: contentsResponse, dampingFraction: contentsDamping)
            .delay(staggerDelay(index: index))
    }

    static func crossfade(reduced: Bool) -> Animation {
        .easeInOut(duration: reduced ? MBMetrics.reducedMotionDuration : crossfadeDuration)
    }

    static func duration(expanded: Bool, reduced: Bool) -> TimeInterval {
        reduced ? MBMetrics.reducedMotionDuration : expanded ? MBMetrics.openDuration : MBMetrics.closeDuration
    }

    static func panelDuration(reduced: Bool) -> TimeInterval {
        reduced ? MBMetrics.reducedMotionDuration : MBMetrics.panelDuration
    }
}
