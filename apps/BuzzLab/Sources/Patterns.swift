import CoreHaptics
import SwiftUI

struct HapticPattern: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    let build: () -> (events: [CHHapticEvent], curves: [CHHapticParameterCurve])

    func play() {
        let p = build()
        HapticManager.shared.play(p.events, curves: p.curves)
    }
}

private typealias H = HapticManager

enum Patterns {
    static let all: [HapticPattern] = [
        HapticPattern(name: "Heartbeat", icon: "heart.fill", color: .red) {
            var e: [CHHapticEvent] = []
            for i in 0..<4 {
                let t = Double(i) * 0.8
                e.append(H.tap(t, intensity: 1.0, sharpness: 0.2))
                e.append(H.tap(t + 0.16, intensity: 0.6, sharpness: 0.1))
            }
            return (e, [])
        },
        HapticPattern(name: "Drumroll", icon: "music.note", color: .orange) {
            var e: [CHHapticEvent] = []
            for i in 0..<35 {
                e.append(H.tap(Double(i) * 0.045, intensity: 0.2 + Float(i) / 35 * 0.6, sharpness: 0.6))
            }
            e.append(H.tap(35 * 0.045 + 0.1, intensity: 1.0, sharpness: 1.0))
            e.append(H.buzz(35 * 0.045 + 0.1, duration: 0.3, intensity: 0.8, sharpness: 0.3))
            return (e, [])
        },
        HapticPattern(name: "SOS", icon: "sos", color: .yellow) {
            var e: [CHHapticEvent] = []
            var t = 0.0
            func dot() { e.append(H.buzz(t, duration: 0.1, sharpness: 0.7)); t += 0.2 }
            func dash() { e.append(H.buzz(t, duration: 0.35, sharpness: 0.7)); t += 0.45 }
            dot(); dot(); dot(); t += 0.25
            dash(); dash(); dash(); t += 0.25
            dot(); dot(); dot()
            return (e, [])
        },
        HapticPattern(name: "Power Up", icon: "bolt.fill", color: .green) {
            let e = [H.buzz(0, duration: 2.0, intensity: 1.0, sharpness: 0.1)]
            let intensity = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [.init(relativeTime: 0, value: 0.05), .init(relativeTime: 1.8, value: 1.0), .init(relativeTime: 2.0, value: 0)],
                relativeTime: 0)
            let sharp = CHHapticParameterCurve(
                parameterID: .hapticSharpnessControl,
                controlPoints: [.init(relativeTime: 0, value: -0.4), .init(relativeTime: 2.0, value: 0.6)],
                relativeTime: 0)
            return (e + [H.tap(2.0, intensity: 1, sharpness: 1)], [intensity, sharp])
        },
        HapticPattern(name: "Raindrops", icon: "cloud.rain.fill", color: .cyan) {
            let e = (0..<30).map { _ in
                H.tap(Double.random(in: 0...3), intensity: .random(in: 0.2...0.8), sharpness: .random(in: 0.5...1.0))
            }
            return (e, [])
        },
        HapticPattern(name: "Knock Knock", icon: "door.left.hand.closed", color: .brown) {
            let e = [0, 0.18, 0.7, 0.88].map { H.tap($0, intensity: 1.0, sharpness: 0.85) }
            return (e, [])
        },
        HapticPattern(name: "Earthquake", icon: "waveform.path.ecg", color: .purple) {
            var e = [H.buzz(0, duration: 2.5, intensity: 1.0, sharpness: 0.0)]
            for _ in 0..<20 {
                e.append(H.tap(Double.random(in: 0...2.5), intensity: .random(in: 0.6...1.0), sharpness: .random(in: 0...0.3)))
            }
            let wobble = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: stride(from: 0.0, through: 2.5, by: 0.15).map { (t: Double) -> CHHapticParameterCurve.ControlPoint in
                    CHHapticParameterCurve.ControlPoint(relativeTime: t, value: Float.random(in: 0.3...1.0))
                },
                relativeTime: 0)
            return (e, [wobble])
        },
        HapticPattern(name: "Alarm", icon: "alarm.fill", color: .pink) {
            let e = (0..<5).map { H.buzz(Double($0) * 0.4, duration: 0.25, intensity: 1.0, sharpness: 0.95) }
            return (e, [])
        },
        HapticPattern(name: "Countdown", icon: "timer", color: .mint) {
            var e = (0..<3).map { H.tap(Double($0), intensity: 0.7, sharpness: 0.5) }
            e.append(H.buzz(3.0, duration: 0.6, intensity: 1.0, sharpness: 0.4))
            return (e, [])
        },
        HapticPattern(name: "Bouncing Ball", icon: "basketball.fill", color: .orange) {
            var e: [CHHapticEvent] = []
            var t = 0.0, gap = 0.5
            var strength: Float = 1.0
            for _ in 0..<12 {
                e.append(H.tap(t, intensity: strength, sharpness: 0.4))
                t += gap; gap *= 0.75; strength *= 0.85
            }
            return (e, [])
        },
        HapticPattern(name: "Engine Rev", icon: "car.fill", color: .blue) {
            let e = [H.buzz(0, duration: 2.4, intensity: 1.0, sharpness: 0.3)]
            let curve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0, value: 0.3), .init(relativeTime: 0.4, value: 1.0),
                    .init(relativeTime: 0.8, value: 0.3), .init(relativeTime: 1.3, value: 1.0),
                    .init(relativeTime: 1.8, value: 0.4), .init(relativeTime: 2.4, value: 0.0),
                ],
                relativeTime: 0)
            return (e, [curve])
        },
        HapticPattern(name: "Cat Purr", icon: "cat.fill", color: .indigo) {
            var e: [CHHapticEvent] = []
            for i in 0..<6 {
                let t = Double(i) * 0.5
                e.append(H.buzz(t, duration: 0.3, intensity: 0.5, sharpness: 0.0))
            }
            return (e, [])
        },
    ]
}
