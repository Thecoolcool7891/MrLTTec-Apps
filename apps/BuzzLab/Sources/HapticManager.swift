import CoreHaptics
import UIKit

/// Wraps Core Haptics (custom patterns) and UIKit feedback generators (system taps).
final class HapticManager {
    static let shared = HapticManager()

    let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var continuousPlayer: CHHapticAdvancedPatternPlayer?

    private init() {
        guard supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            try engine.start()
            self.engine = engine
        } catch {
            print("Haptic engine failed to start: \(error)")
        }
    }

    // MARK: - System feedback (UIKit)

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1.0) {
        let gen = UIImpactFeedbackGenerator(style: style)
        gen.prepare()
        gen.impactOccurred(intensity: intensity)
    }

    func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(type)
    }

    func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: - Custom patterns (Core Haptics)

    func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve] = []) {
        guard let engine else { return }
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("Pattern failed: \(error)")
        }
    }

    // MARK: - Live continuous rumble (Touch Pad)

    /// Starts a long continuous vibration whose strength can be changed live.
    func startContinuous() {
        guard let engine, continuousPlayer == nil else { return }
        do {
            try engine.start()
            let event = HapticManager.buzz(0, duration: 60, intensity: 1.0, sharpness: 0.5)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            continuousPlayer = player
        } catch {
            print("Continuous failed: \(error)")
        }
    }

    /// intensity 0...1, sharpness 0...1
    func updateContinuous(intensity: Float, sharpness: Float) {
        guard let continuousPlayer else { return }
        let params = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
            // sharpness control is an offset (-1...1) added to the event's 0.5 base
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
        ]
        try? continuousPlayer.sendParameters(params, atTime: CHHapticTimeImmediate)
    }

    func stopContinuous() {
        try? continuousPlayer?.stop(atTime: CHHapticTimeImmediate)
        continuousPlayer = nil
    }

    // MARK: - Event builders

    static func tap(_ time: TimeInterval, intensity: Float = 1.0, sharpness: Float = 0.5) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time
        )
    }

    static func buzz(_ time: TimeInterval, duration: TimeInterval, intensity: Float = 1.0, sharpness: Float = 0.5) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time,
            duration: duration
        )
    }
}
