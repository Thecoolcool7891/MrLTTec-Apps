import SwiftUI
import UIKit

// MARK: - Shared button

struct BuzzButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(
                LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? 0.1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private let grid = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

private struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }
}

// MARK: - Basics tab

struct BasicsView: View {
    private let hm = HapticManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if !hm.supportsHaptics {
                    Text("This device doesn't report Core Haptics support. Basic taps may still work.")
                        .font(.footnote).foregroundStyle(.yellow)
                }

                SectionHeader(text: "Impacts")
                LazyVGrid(columns: grid, spacing: 14) {
                    BuzzButton(title: "Light", icon: "circle", color: .teal) { hm.impact(.light) }
                    BuzzButton(title: "Medium", icon: "circle.lefthalf.filled", color: .blue) { hm.impact(.medium) }
                    BuzzButton(title: "Heavy", icon: "circle.fill", color: .indigo) { hm.impact(.heavy) }
                    BuzzButton(title: "Soft", icon: "cloud.fill", color: .gray) { hm.impact(.soft) }
                    BuzzButton(title: "Rigid", icon: "cube.fill", color: .brown) { hm.impact(.rigid) }
                    BuzzButton(title: "Selection Tick", icon: "dial.medium.fill", color: .mint) { hm.selection() }
                }

                SectionHeader(text: "Notifications")
                LazyVGrid(columns: grid, spacing: 14) {
                    BuzzButton(title: "Success", icon: "checkmark.circle.fill", color: .green) { hm.notify(.success) }
                    BuzzButton(title: "Warning", icon: "exclamationmark.triangle.fill", color: .orange) { hm.notify(.warning) }
                    BuzzButton(title: "Error", icon: "xmark.octagon.fill", color: .red) { hm.notify(.error) }
                }
            }
            .padding()
        }
    }
}

// MARK: - Patterns tab

struct PatternsView: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: grid, spacing: 14) {
                ForEach(Patterns.all) { p in
                    BuzzButton(title: p.name, icon: p.icon, color: p.color) { p.play() }
                }
            }
            .padding()
        }
    }
}

// MARK: - Touch Pad tab

struct TouchPadView: View {
    @State private var touch: CGPoint?
    @State private var intensity: Float = 0
    @State private var sharpness: Float = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Drag your finger. Up = stronger, right = sharper.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [.purple.opacity(0.35), .orange.opacity(0.6)],
                                             startPoint: .bottomLeading, endPoint: .topTrailing))
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)

                    if let touch {
                        Circle()
                            .fill(.white.opacity(0.9))
                            .frame(width: 40 + CGFloat(intensity) * 60, height: 40 + CGFloat(intensity) * 60)
                            .blur(radius: 6)
                            .position(touch)
                    } else {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 50))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(max(value.location.x, 0), geo.size.width)
                            let y = min(max(value.location.y, 0), geo.size.height)
                            touch = CGPoint(x: x, y: y)
                            sharpness = Float(x / geo.size.width)
                            intensity = Float(1 - y / geo.size.height)
                            HapticManager.shared.startContinuous()
                            HapticManager.shared.updateContinuous(intensity: intensity, sharpness: sharpness)
                        }
                        .onEnded { _ in
                            touch = nil
                            HapticManager.shared.stopContinuous()
                        }
                )
            }

            HStack {
                Label("\(Int(intensity * 100))%", systemImage: "arrow.up")
                Spacer()
                Label("\(Int(sharpness * 100))%", systemImage: "arrow.right")
            }
            .font(.headline.monospacedDigit())
        }
        .padding()
        .onDisappear { HapticManager.shared.stopContinuous() }
    }
}
