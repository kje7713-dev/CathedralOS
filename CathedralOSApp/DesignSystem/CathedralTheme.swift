import SwiftUI

// MARK: - Cathedral Design System
// Centralized color tokens, typography, spacing, and reusable components.
// Architecture: severe, clean, intelligent, private.
// Palette: black / white / charcoal / restrained brass accent.

// MARK: - Color Tokens

enum CathedralTheme {

    // MARK: Colors

    enum Colors {
        // Base surfaces
        static let background = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)
                : UIColor.systemBackground
        })

        static let surface = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.11, green: 0.11, blue: 0.115, alpha: 1)
                : UIColor.secondarySystemBackground
        })

        static let surfaceRaised = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.14, green: 0.14, blue: 0.145, alpha: 1)
                : UIColor.tertiarySystemBackground
        })

        // Borders
        static let border = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1)
                : UIColor(red: 0.82, green: 0.82, blue: 0.84, alpha: 1)
        })

        static let borderSubtle = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.17, green: 0.17, blue: 0.17, alpha: 1)
                : UIColor(red: 0.88, green: 0.88, blue: 0.90, alpha: 1)
        })

        // Text hierarchy
        static let primaryText = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
                : UIColor.label
        })

        static let secondaryText = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.55, green: 0.55, blue: 0.56, alpha: 1)
                : UIColor.secondaryLabel
        })

        static let tertiaryText = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.38, green: 0.38, blue: 0.39, alpha: 1)
                : UIColor.tertiaryLabel
        })

        // Accent — restrained brass/gold, used sparingly; adaptive for light/dark
        static let accent = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.80, green: 0.70, blue: 0.50, alpha: 1)  // warm brass on dark
                : UIColor(red: 0.60, green: 0.50, blue: 0.32, alpha: 1)  // deeper brass on light
        })

        // Destructive
        static let destructive = Color(UIColor.systemRed)

        // Separator
        static let separator = Color(UIColor { t in
            t.userInterfaceStyle == .dark
                ? UIColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1)
                : UIColor.separator
        })
    }

    // MARK: Typography

    enum Typography {
        static func display(_ size: CGFloat = 28, weight: Font.Weight = .bold) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func headline(_ size: CGFloat = 17, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func body(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func caption(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func label(_ size: CGFloat = 11, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat   = 4
        static let sm: CGFloat   = 8
        static let md: CGFloat   = 12
        static let base: CGFloat = 16
        static let lg: CGFloat   = 20
        static let xl: CGFloat   = 24
        static let xxl: CGFloat  = 32
    }

    // MARK: Radius

    enum Radius {
        static let sm: CGFloat   = 8
        static let md: CGFloat   = 12
        static let lg: CGFloat   = 16
    }

    // MARK: Icon Sizes

    enum Icons {
        /// Delete / remove control (tag rows, list items).
        static let deleteControl: CGFloat = 16
        /// Checkmark in single-selection rows.
        static let selectionMark: CGFloat = 13
        /// Large glyph in full-screen empty states.
        static let emptyStateGlyph: CGFloat = 44
    }
}

// MARK: - View Modifiers

extension View {
    /// Applies the Cathedral background color to this view.
    func cathedralBackground() -> some View {
        self.background(CathedralTheme.Colors.background.ignoresSafeArea())
    }

    /// Hides the default form/list background and applies Cathedral surface.
    func cathedralFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(CathedralTheme.Colors.background.ignoresSafeArea())
    }
}

// MARK: - CathedralCard

/// Subtle elevated surface — used for feature blocks and containers.
struct CathedralCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(CathedralTheme.Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CathedralTheme.Colors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                    .stroke(CathedralTheme.Colors.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
    }
}

// MARK: - CathedralPrimaryButton

/// Full-width primary CTA — bold, inverted, uppercase with tracking.
struct CathedralPrimaryButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CathedralTheme.Spacing.sm) {
                if let img = systemImage {
                    Image(systemName: img)
                        .imageScale(.small)
                }
                Text(title.uppercased())
                    .tracking(1.2)
            }
            .font(CathedralTheme.Typography.label(12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(colorScheme == .dark ? CathedralTheme.Colors.background : .white)
            .background(
                isEnabled
                    ? (colorScheme == .dark ? CathedralTheme.Colors.primaryText : Color.black)
                    : CathedralTheme.Colors.border
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CathedralSecondaryButton

/// Outlined secondary action — same sizing as primary but ghost style.
struct CathedralSecondaryButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CathedralTheme.Spacing.sm) {
                if let img = systemImage {
                    Image(systemName: img)
                        .imageScale(.small)
                }
                Text(title.uppercased())
                    .tracking(1.2)
            }
            .font(CathedralTheme.Typography.label(12, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(
                isEnabled
                    ? CathedralTheme.Colors.primaryText
                    : CathedralTheme.Colors.secondaryText
            )
            .overlay(
                RoundedRectangle(cornerRadius: CathedralTheme.Radius.md)
                    .stroke(
                        isEnabled
                            ? CathedralTheme.Colors.border
                            : CathedralTheme.Colors.borderSubtle,
                        lineWidth: 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: CathedralTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CathedralSectionHeader

/// Section header with uppercase label + inline add button using the accent.
struct CathedralSectionHeader: View {
    let title: String
    let onAdd: (() -> Void)?

    init(_ title: String, onAdd: (() -> Void)? = nil) {
        self.title = title
        self.onAdd = onAdd
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title.uppercased())
                .font(CathedralTheme.Typography.label(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(CathedralTheme.Colors.secondaryText)

            Spacer()

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CathedralTheme.Colors.accent)
                        .frame(width: 28, height: 28)
                        .background(CathedralTheme.Colors.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(CathedralTheme.Colors.border, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, CathedralTheme.Spacing.xs)
    }
}

// MARK: - CathedralItemRow

/// Standard list row for a titled item with optional sensitive indicator.
struct CathedralItemRow: View {
    let title: String
    let subtitle: String?
    let isSensitive: Bool
    let onTap: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        isSensitive: Bool = false,
        onTap: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSensitive = isSensitive
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: CathedralTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CathedralTheme.Typography.body(15))
                    .foregroundStyle(CathedralTheme.Colors.primaryText)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(CathedralTheme.Typography.caption())
                        .foregroundStyle(CathedralTheme.Colors.secondaryText)
                }
            }
            Spacer()
            if isSensitive {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            }
        }
        .padding(.vertical, CathedralTheme.Spacing.sm)
        .padding(.horizontal, CathedralTheme.Spacing.base)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - CathedralEmptyState

/// Empty state placeholder for sections with no items.
struct CathedralEmptyState: View {
    let label: String

    var body: some View {
        Text(label)
            .font(CathedralTheme.Typography.caption())
            .foregroundStyle(CathedralTheme.Colors.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CathedralTheme.Spacing.sm)
            .padding(.horizontal, CathedralTheme.Spacing.base)
    }
}

// MARK: - CathedralDivider

struct CathedralDivider: View {
    var body: some View {
        Rectangle()
            .fill(CathedralTheme.Colors.separator)
            .frame(height: 1)
            .padding(.leading, CathedralTheme.Spacing.base)
    }
}

// MARK: - CathedralTagChip

/// Display-only pill chip for a single tag value.
/// Use inside ForEach to render a collection of tags.
struct CathedralTagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(CathedralTheme.Typography.caption(12))
            .foregroundStyle(CathedralTheme.Colors.primaryText)
            .padding(.horizontal, CathedralTheme.Spacing.sm)
            .padding(.vertical, CathedralTheme.Spacing.xs)
            .background(CathedralTheme.Colors.surfaceRaised)
            .overlay(
                Capsule()
                    .stroke(CathedralTheme.Colors.border, lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

// MARK: - CathedralFormSectionHeader

/// Branded section header for use inside SwiftUI Form `Section` headers.
/// Applies Cathedral uppercase + tracking typography and suppresses the
/// system's automatic uppercasing via `.textCase(nil)`.
struct CathedralFormSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(CathedralTheme.Typography.label(10, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .textCase(nil)
    }
}

// MARK: - CathedralNavRowLabel

/// Visual row content for use as a `NavigationLink` label.
/// Matches `CathedralItemRow` visuals but carries NO `.onTapGesture`,
/// preventing gesture interception on the enclosing NavigationLink.
struct CathedralNavRowLabel: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(CathedralTheme.Typography.body(15))
                .foregroundStyle(CathedralTheme.Colors.primaryText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(CathedralTheme.Typography.caption())
                    .foregroundStyle(CathedralTheme.Colors.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, CathedralTheme.Spacing.sm)
    }
}

// MARK: - CathedralMetadataPill

/// Small inline metadata label — used for count badges and status labels.
struct CathedralMetadataPill: View {
    let label: String

    var body: some View {
        Text(label)
            .font(CathedralTheme.Typography.label(10, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(CathedralTheme.Colors.secondaryText)
            .padding(.horizontal, CathedralTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(CathedralTheme.Colors.surfaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(CathedralTheme.Colors.borderSubtle, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
