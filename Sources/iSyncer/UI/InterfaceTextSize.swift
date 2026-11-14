import SwiftUI

enum InterfaceTextSize: Int, CaseIterable, Identifiable {
    case standard = 0
    case large = 2
    case extraLarge = 4

    static let storageKey = "interfaceTextSize"
    var id: Self { self }
    var extra: CGFloat { CGFloat(rawValue) }

    var label: String {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    static var saved: Self {
        Self(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .standard
    }

    func font(_ base: CGFloat) -> Font { Theme.listFont(base + extra) }
    func bold(_ base: CGFloat) -> Font { Theme.listBoldFont(base + extra) }

    func apply(to view: AnyView) -> AnyView {
        AnyView(view.font(.system(size: 13 + extra)).environment(\.interfaceTextSize, self))
    }
}

private struct InterfaceTextSizeKey: EnvironmentKey {
    static let defaultValue = InterfaceTextSize.standard
}

extension EnvironmentValues {
    var interfaceTextSize: InterfaceTextSize {
        get { self[InterfaceTextSizeKey.self] }
        set { self[InterfaceTextSizeKey.self] = newValue }
    }
}

private struct InterfaceTypography: ViewModifier {
    @AppStorage(InterfaceTextSize.storageKey) private var size = InterfaceTextSize.standard

    func body(content: Content) -> some View {
        content.font(.system(size: 13 + size.extra)).environment(\.interfaceTextSize, size)
    }
}

extension View {
    func interfaceTypography() -> some View { modifier(InterfaceTypography()) }
}
