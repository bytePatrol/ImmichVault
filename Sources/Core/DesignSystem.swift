import SwiftUI

// MARK: - ImmichVault Design System
// A cohesive design system for a premium macOS app experience.

public enum IVSpacing {
    /// 2pt
    public static let xxxs: CGFloat = 2
    /// 4pt
    public static let xxs: CGFloat = 4
    /// 6pt
    public static let xs: CGFloat = 6
    /// 8pt
    public static let sm: CGFloat = 8
    /// 12pt
    public static let md: CGFloat = 12
    /// 16pt
    public static let lg: CGFloat = 16
    /// 20pt
    public static let xl: CGFloat = 20
    /// 24pt
    public static let xxl: CGFloat = 24
    /// 32pt
    public static let xxxl: CGFloat = 32
    /// 48pt
    public static let xxxxl: CGFloat = 48
}

public enum IVCornerRadius {
    public static let sm: CGFloat = 4
    public static let md: CGFloat = 8
    public static let lg: CGFloat = 12
    public static let xl: CGFloat = 16
}

public enum IVFont {
    public static let displayLarge = Font.system(size: 28, weight: .bold, design: .default)
    public static let displayMedium = Font.system(size: 22, weight: .semibold, design: .default)
    public static let headline = Font.system(size: 17, weight: .semibold, design: .default)
    public static let subheadline = Font.system(size: 15, weight: .medium, design: .default)
    public static let body = Font.system(size: 13, weight: .regular, design: .default)
    public static let bodyMedium = Font.system(size: 13, weight: .medium, design: .default)
    public static let caption = Font.system(size: 11, weight: .regular, design: .default)
    public static let captionMedium = Font.system(size: 11, weight: .medium, design: .default)
    public static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)
}

// MARK: - Color Tokens

public extension Color {
    // Brand
    static let ivPrimary = Color("IVPrimary", bundle: nil)
    static let ivSecondary = Color("IVSecondary", bundle: nil)

    // Semantic - using system colors for native feel
    static let ivBackground = Color(nsColor: .windowBackgroundColor)
    static let ivSurface = Color(nsColor: .controlBackgroundColor)
    static let ivSurfaceElevated = Color(nsColor: .underPageBackgroundColor)
    static let ivBorder = Color(nsColor: .separatorColor)
    static let ivTextPrimary = Color(nsColor: .labelColor)
    static let ivTextSecondary = Color(nsColor: .secondaryLabelColor)
    static let ivTextTertiary = Color(nsColor: .tertiaryLabelColor)

    // Status
    static let ivSuccess = Color.green
    static let ivWarning = Color.orange
    static let ivError = Color.red
    static let ivInfo = Color.blue

    // Accent
    static let ivAccent = Color.accentColor
}

// MARK: - Reusable Components

public struct IVCard<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(IVSpacing.lg)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.lg)
                    .fill(Color.ivSurface)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
    }
}

public struct IVSectionHeader: View {
    let title: String
    let subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: IVSpacing.xxs) {
            Text(title)
                .font(IVFont.headline)
                .foregroundColor(.ivTextPrimary)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(IVFont.caption)
                    .foregroundColor(.ivTextSecondary)
            }
        }
    }
}

public struct IVStatusBadge: View {
    public enum Status: Sendable {
        case success, warning, error, info, idle, processing
    }

    let label: String
    let status: Status
    let animated: Bool

    @State private var isAnimating = false

    public init(_ label: String, status: Status, animated: Bool = false) {
        self.label = label
        self.status = status
        self.animated = animated
    }

    private var color: Color {
        switch status {
        case .success: return .ivSuccess
        case .warning: return .ivWarning
        case .error: return .ivError
        case .info: return .ivInfo
        case .idle: return .ivTextTertiary
        case .processing: return .ivAccent
        }
    }

    public var body: some View {
        HStack(spacing: IVSpacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(animated && isAnimating ? 0.4 : 1.0)
                .animation(
                    animated ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                    value: isAnimating
                )
            Text(label)
                .font(IVFont.captionMedium)
                .foregroundColor(.ivTextSecondary)
        }
        .padding(.horizontal, IVSpacing.sm)
        .padding(.vertical, IVSpacing.xxs)
        .background {
            Capsule()
                .fill(color.opacity(0.1))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .onAppear {
            if animated {
                isAnimating = true
            }
        }
    }
}

public struct IVEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    public init(
        icon: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: IVSpacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.ivTextTertiary)

            VStack(spacing: IVSpacing.xs) {
                Text(title)
                    .font(IVFont.headline)
                    .foregroundColor(.ivTextPrimary)
                Text(message)
                    .font(IVFont.body)
                    .foregroundColor(.ivTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(IVFont.bodyMedium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(IVSpacing.xxxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Loading Skeleton

public struct IVSkeletonRow: View {
    @State private var isAnimating = false

    public init() {}

    public var body: some View {
        HStack(spacing: IVSpacing.md) {
            RoundedRectangle(cornerRadius: IVCornerRadius.sm)
                .fill(Color.ivTextTertiary.opacity(0.15))
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: IVSpacing.xs) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.ivTextTertiary.opacity(0.15))
                    .frame(width: 140, height: 10)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.ivTextTertiary.opacity(0.1))
                    .frame(width: 90, height: 8)
            }

            Spacer()
        }
        .opacity(isAnimating ? 0.5 : 1.0)
        .animation(
            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
            value: isAnimating
        )
        .onAppear { isAnimating = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Grouped Panel

public struct IVGroupedPanel<Content: View>: View {
    let title: String
    let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: IVSpacing.sm) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.ivTextTertiary)
                .tracking(0.5)
            content
        }
        .padding(IVSpacing.lg)
        .background {
            RoundedRectangle(cornerRadius: IVCornerRadius.md)
                .fill(Color.ivSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: IVCornerRadius.md)
                        .stroke(Color.ivBorder.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Section Card Modifier

struct SectionCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, IVSpacing.md)
            .padding(.vertical, IVSpacing.sm)
            .background {
                RoundedRectangle(cornerRadius: IVCornerRadius.md)
                    .fill(Color.ivSurface.opacity(0.18))
            }
    }
}

extension View {
    func sectionCard() -> some View {
        modifier(SectionCardModifier())
    }
}
