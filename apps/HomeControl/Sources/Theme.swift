import SwiftUI
import UIKit

/// The tan look from the mockup.
enum Tan {
    static let bg = Color(hex: 0xEFE2D0)
    static let card = Color(hex: 0xFBF5EC)
    static let line = Color(hex: 0xDCC7AD)
    static let chip = Color(hex: 0xE6D3BA)
    static let chipText = Color(hex: 0x5A3A24)
    static let iconFg = Color(hex: 0x6B4429)
    static let text = Color(hex: 0x3B2717)
    static let muted = Color(hex: 0x8A6A50)
    static let faint = Color(hex: 0xA08670)
    static let brown = Color(hex: 0x8B5A35)
    static let dark = Color(hex: 0x3B2717)
    static let art = Color(hex: 0xC99A6E)
    static let bar = Color(hex: 0xF6ECDF)
    static let row = Color(hex: 0xE2D0B9)
    static let sheetBack = Color(hex: 0xCDB79C)
    static let greenBg = Color(hex: 0xD4ECD6)
    static let greenFg = Color(hex: 0x1E5A2A)
    static let greenSub = Color(hex: 0x2F7A3D)
    static let gold = Color(hex: 0xC98A00)
    static let switchOff = Color(hex: 0xD6C2A8)
    static let switchOn = Color(hex: 0x34C759)
    static let bad = Color(hex: 0xB3261E)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
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

struct IconBox: View {
    let symbol: String
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(Tan.iconFg)
            .frame(width: size, height: size)
            .background(Tan.chip, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    var icon: String? = nil
    var bg: Color = Tan.chip
    var fg: Color = Tan.chipText
    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(bg, in: Capsule())
    }
}

/// The iOS-style switch from the mockup. `scale` makes it smaller (the Gaming PC uses a smaller one).
struct TanSwitch: View {
    let on: Bool
    var scale: CGFloat = 1
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Tan.switchOn : Tan.switchOff)
                Circle().fill(.white).padding(2 * scale)
            }
            .frame(width: 46 * scale, height: 28 * scale)
            .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(.plain)
    }
}

/// Song cover, or the tan disc square when there is none.
struct ArtBox: View {
    let url: URL?
    var size: CGFloat = 48
    var body: some View {
        ZStack {
            Tan.art
            Image(systemName: "music.note").font(.system(size: size * 0.42)).foregroundStyle(Tan.card)
            if let url = url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.17, style: .continuous))
    }
}

// MARK: - Rainbow fan (the CPU cooler's RGB light)

/// One fan blade, drawn on a 32 x 32 grid (same shape as the web page's fan).
struct FanBlade: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(16, 16))
        path.addCurve(to: p(16, 2.5), control1: p(12.5, 12), control2: p(12, 5.5))
        path.addCurve(to: p(22.5, 12), control1: p(21, 3), control2: p(23.5, 7))
        path.closeSubpath()
        return path
    }
}

struct RainbowFan: View {
    static let hexes: [UInt32] = [0xFF3B30, 0xFF9F0A, 0xFFCC00, 0x34C759, 0x0A84FF, 0xAF52DE]
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                FanBlade().fill(Color(hex: Self.hexes[i])).rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(Tan.card).scaleEffect(0.2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A picture shipped inside the app (Sources/Icons), like Landon's app icons. WebP works too.
struct BundleIcon: View {
    let file: String
    var size: CGFloat = 56
    var corner: CGFloat? = nil

    private var image: UIImage? {
        let parts = file.split(separator: ".")
        guard parts.count == 2, let p = Bundle.main.path(forResource: String(parts[0]), ofType: String(parts[1])) else { return nil }
        return UIImage(contentsOfFile: p)
    }

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack { Tan.chip; Image(systemName: "app").foregroundStyle(Tan.iconFg) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner ?? size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner ?? size * 0.225, style: .continuous).stroke(Tan.line, lineWidth: 0.5))
    }
}
