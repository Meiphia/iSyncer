import SwiftUI
import AppKit

/// Late-2000s jukebox chrome: brushed greys, a pale LCD, glossy round buttons, a blue-grey
/// source list. Original drawing — no Apple artwork.
enum Theme {
    static func hex(_ v: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255,
              opacity: a)
    }

    static let chromeTop = hex(0xDCDCDC)
    static let chromeBottom = hex(0xA9A9A9)
    static let chromeLine = hex(0x6E6E6E)
    static let statusTop = hex(0xD2D2D2)
    static let statusBottom = hex(0xB0B0B0)

    static let lcdTop = hex(0xF1F4E6)
    static let lcdBottom = hex(0xD5DCC4)
    static let lcdStroke = hex(0x7D8270)
    static let lcdText = hex(0x262A1E)
    static let lcdDim = hex(0x5A6050)

    static let sourceBackground = hex(0xD5DCE6)
    static let sourceHeader = hex(0x6F7A8A)
    static let selectionTop = hex(0x6D9DE0)
    static let selectionBottom = hex(0x2F6BC9)

    static let capacityAudio = hex(0x3B8FE8)
    static let capacityVideo = hex(0x9B5FD6)
    static let capacityOther = hex(0xF2B53A)
    static let capacityFree = hex(0xF4F4F4)

    /// Lucida Grande, the Mac UI font of the iTunes 6 era, when the system still has it.
    static func listFont(_ size: CGFloat) -> Font {
        NSFont(name: "LucidaGrande", size: size) != nil ? .custom("LucidaGrande", size: size) : .system(size: size)
    }

    static func listBoldFont(_ size: CGFloat) -> Font {
        NSFont(name: "LucidaGrande-Bold", size: size) != nil ? .custom("LucidaGrande-Bold", size: size) : .system(size: size, weight: .bold)
    }

    /// Glossy Aqua header: light top half, a crisp step, slightly darker bottom half.
    static var glossyHeader: LinearGradient {
        LinearGradient(stops: [
            .init(color: hex(0xFEFEFE), location: 0), .init(color: hex(0xF1F1F1), location: 0.5),
            .init(color: hex(0xE3E3E3), location: 0.5), .init(color: hex(0xEEEEEE), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    static var chrome: LinearGradient {
        LinearGradient(colors: [chromeTop, chromeBottom], startPoint: .top, endPoint: .bottom)
    }
    static var statusBar: LinearGradient {
        LinearGradient(colors: [statusTop, statusBottom], startPoint: .top, endPoint: .bottom)
    }
    static var lcd: LinearGradient {
        LinearGradient(colors: [lcdTop, lcdBottom], startPoint: .top, endPoint: .bottom)
    }
    static var selection: LinearGradient {
        LinearGradient(colors: [selectionTop, selectionBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// Glossy round transport button.
struct RoundButtonStyle: ButtonStyle {
    var diameter: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: diameter * 0.36, weight: .bold))
            .foregroundStyle(Theme.hex(0x2A2A2A))
            .frame(width: diameter, height: diameter)
            .background(
                ZStack {
                    Circle().fill(LinearGradient(
                        colors: pressed ? [Theme.hex(0xA8A8A8), Theme.hex(0xD8D8D8)]
                                        : [Theme.hex(0xFDFDFD), Theme.hex(0xC4C4C4)],
                        startPoint: .top, endPoint: .bottom))
                    // gloss
                    Circle()
                        .trim(from: 0.5, to: 1)
                        .fill(Color.white.opacity(pressed ? 0.1 : 0.45))
                        .scaleEffect(0.86)
                        .rotationEffect(.degrees(180))
                    Circle().strokeBorder(Theme.hex(0x5E5E5E), lineWidth: 1)
                }
            )
            .shadow(color: .white.opacity(0.7), radius: 0, x: 0, y: 1)
    }
}

/// Glossy grey button with compact icon and text sizes.
struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.interfaceTextSize) private var textSize
    var active = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 + (compact ? 0 : textSize.extra), weight: .semibold))
            .foregroundStyle(active ? Theme.hex(0x1F5FC4) : Theme.hex(0x333333))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 0 : 10)
            .frame(width: compact ? 30 : nil, height: compact ? 22 : 25 + textSize.extra)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: configuration.isPressed ? [Theme.hex(0xB5B5B5), Theme.hex(0xD5D5D5)]
                                                        : [Theme.hex(0xF6F6F6), Theme.hex(0xCDCDCD)],
                        startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hex(0x7A7A7A), lineWidth: 1))
    }
}

/// Aqua-ish pill button for Sync / Apply.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.interfaceTextSize) private var textSize
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = prominent && isEnabled
        let top = highlighted ? Theme.hex(0x8EC0F7) : Theme.hex(0xFBFBFB)
        let bottom = highlighted ? Theme.hex(0x2F78D8) : Theme.hex(0xCFCFCF)
        return configuration.label
            .font(.system(size: 13 + textSize.extra, weight: .semibold))
            .foregroundStyle(highlighted ? .white : Theme.hex(isEnabled ? 0x222222 : 0x777777))
            .padding(.horizontal, 22)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(LinearGradient(colors: configuration.isPressed ? [bottom, top] : [top, bottom],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(Theme.hex(highlighted ? 0x1D4F99 : 0x7C7C7C), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
    }
}

/// Generic hard-drive-jukebox glyph used for devices (original drawing).
@MainActor
struct PlayerGlyph: View {
    var size: CGFloat = 16

    /// The rendered player picture (Resources/Player.png, copied into the app by build.sh).
    static let picture: NSImage? = Bundle.main.url(forResource: "Player", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if size >= 28, let pic = Self.picture {
            Image(nsImage: pic)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.66, height: size)
        } else {
            drawn
        }
    }

    private var drawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(LinearGradient(colors: [Theme.hex(0xFAFAFA), Theme.hex(0xBDBDBD)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.18).strokeBorder(Theme.hex(0x555555), lineWidth: max(0.5, size / 32)))
            VStack(spacing: size * 0.08) {
                RoundedRectangle(cornerRadius: size * 0.04)
                    .fill(LinearGradient(colors: [Theme.hex(0xEEF5DF), Theme.hex(0xB5CB92)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.04).strokeBorder(Theme.hex(0x2A2D33), lineWidth: max(0.75, size / 20)))
                    .frame(width: size * 0.5, height: size * 0.36)
                Circle()
                    .strokeBorder(Theme.hex(0x777777), lineWidth: max(0.5, size / 24))
                    .frame(width: size * 0.36, height: size * 0.36)
            }
        }
        .frame(width: size * 0.66, height: size)
    }
}
