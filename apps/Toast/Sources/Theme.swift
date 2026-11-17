import SwiftUI
import UIKit

/// The MrLTTec brown / tan look.
enum Tan {
    static let bg = Color(hex: 0xEFE2D0)
    static let card = Color(hex: 0xFBF5EC)
    static let line = Color(hex: 0xDCC7AD)
    static let chip = Color(hex: 0xE6D3BA)
    static let chipText = Color(hex: 0x5A3A24)
    static let text = Color(hex: 0x3B2717)
    static let muted = Color(hex: 0x8A6A50)
    static let faint = Color(hex: 0xA08670)
    static let brown = Color(hex: 0x8B5A35)
    static let dark = Color(hex: 0x3B2717)
    static let crust = Color(hex: 0xC99A6E)
    static let bar = Color(hex: 0xF6ECDF)
    static let row = Color(hex: 0xE2D0B9)
    static let green = Color(hex: 0x2F7A3D)
    static let greenBg = Color(hex: 0xD4ECD6)
    static let gold = Color(hex: 0xC98A00)
    static let orange = Color(hex: 0xD2691E)
    static let bad = Color(hex: 0xB3261E)
    static let badBg = Color(hex: 0xF6D9D5)
    static let silver = Color(hex: 0x8E9AA6)
    static let burgundy = Color(hex: 0x7B1E3A)

    /// Color for a class percent: A green, B olive, C gold, D orange, F red.
    static func grade(_ percent: Double?) -> Color {
        guard let p = percent else { return faint }
        if p >= 90 { return green }
        if p >= 80 { return Color(hex: 0x6B8E23) }
        if p >= 70 { return gold }
        if p >= 60 { return orange }
        return bad
    }

    static func dayColor(_ name: String?) -> Color {
        if name == "silver" { return silver }
        if name == "burgundy" { return burgundy }
        return muted
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func fail() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}

extension View {
    /// Off-white card with the thin tan border.
    func tanCard(padding: CGFloat = 14) -> some View {
        self
            .padding(.horizontal, padding)
            .padding(.vertical, padding - 2)
            .background(Tan.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
    }
}

/// A titled card. Everything on the main screens sits in one of these.
struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = title {
                HStack(spacing: 6) {
                    if let icon = icon {
                        Image(systemName: icon).font(.footnote.weight(.semibold)).foregroundStyle(Tan.brown)
                    }
                    Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Tan.muted)
                    Spacer()
                    if let trailing = trailing {
                        Text(trailing).font(.caption).foregroundStyle(Tan.faint)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tanCard()
    }
}

/// Small rounded label, e.g. "silver day" or "Geo".
struct Pill: View {
    let text: String
    var color: Color = Tan.chipText
    var fill: Color = Tan.chip

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .lineLimit(1)
    }
}

/// Gray helper line for "nothing here" and errors.
struct Note: View {
    let text: String
    var bad: Bool = false

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(bad ? Tan.bad : Tan.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The big brown button.
struct BrownButton: View {
    let title: String
    var icon: String? = nil
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: { Haptic.tap(); action() }) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().tint(.white)
                } else if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(.white)
            .background(Tan.brown, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

/// Horizontal progress bar (0...1).
struct Meter: View {
    let value: Double
    var color: Color = Tan.brown

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Tan.row)
                Capsule().fill(color).frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 7)
    }
}

/// Standard screen background + scroll container.
struct Screen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .background(Tan.bg.ignoresSafeArea())
    }
}
