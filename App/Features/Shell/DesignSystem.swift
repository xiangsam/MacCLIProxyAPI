import SwiftUI

// MARK: - Tokens

enum AppDesign {
    static let contentMaxWidth: CGFloat = 880
    static let pagePadding: CGFloat = 28
    static let pageStackSpacing: CGFloat = 16
    static let cardRadius: CGFloat = 18
    static let sidebarIdeal: CGFloat = 236
    static let controlHeight: CGFloat = 36
    static let metricTileMinHeight: CGFloat = 76

    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    static var pageBackground: some ShapeStyle {
        Color(nsColor: .windowBackgroundColor)
    }
}

enum PageLayout {
    /// Top-aligned scroll (home, versions, config with lots of content).
    case feed
    /// Content vertically + horizontally centered (task / empty stages).
    case stage
    /// Toolbar top + body fills remaining height (lists).
    case fill
}

// MARK: - Cards

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    /// When true, expands to fill proposed height (for equal-height side-by-side cards).
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppDesign.cardRadius, style: .continuous)
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(
                maxWidth: .infinity,
                maxHeight: fillHeight ? .infinity : nil,
                alignment: .topLeading
            )
            .background { cardFill }
            // Clip content (e.g. hero accent bar) to the same rounded rect as the card.
            .clipShape(shape)
            .overlay { shape.strokeBorder(cardStroke, lineWidth: 1) }
            .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
    }

    @ViewBuilder
    private var cardFill: some View {
        if #available(macOS 26.0, *) {
            shape.fill(.regularMaterial)
        } else {
            shape.fill(.background.secondary)
        }
    }

    private var cardStroke: Color {
        if #available(macOS 26.0, *) {
            return .white.opacity(0.10)
        }
        return Color.primary.opacity(0.06)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var icon: String? = nil

    var body: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: AppDesign.metricTileMinHeight, alignment: .topLeading)
        }
    }
}

// MARK: - Controls

/// Unified capsule control used across pages (hero actions, etc.).
struct AppControlButton: View {
    enum Kind {
        case primary
        case secondary
        case danger
        case ghost
    }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .secondary
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.subheadline.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: AppDesign.controlHeight)
            .foregroundStyle(foreground)
            .background(background, in: Capsule(style: .continuous))
            .overlay {
                if kind == .ghost {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return .primary
        case .danger: return AppDesign.danger
        case .ghost: return .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Color.accentColor
        case .secondary: return Color.primary.opacity(0.08)
        case .danger: return AppDesign.danger.opacity(0.14)
        case .ghost: return Color.clear
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content()
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    var tone: Tone = .neutral

    enum Tone {
        case neutral, success, warning, danger, info
        var color: Color {
            switch self {
            case .neutral: return .secondary
            case .success: return .green
            case .warning: return .orange
            case .danger: return .red
            case .info: return .blue
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.color).frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone == .neutral ? Color.primary : tone.color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tone.color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Empty / stage

struct CompactEmptyRow: View {
    var title: String
    var systemImage: String = "tray"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

/// Centered empty state with optional primary action — fills available space.
struct CenteredEmptyState: View {
    var systemImage: String
    var title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Page shells

struct PageContainer<Content: View>: View {
    var layout: PageLayout = .feed
    var maxWidth: CGFloat = AppDesign.contentMaxWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch layout {
        case .feed:
            ScrollView {
                content()
                    .padding(AppDesign.pagePadding)
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.automatic)
            .background(AppDesign.pageBackground)

        case .stage:
            // No scroll needed for centered stage; content owns the height.
            content()
                .padding(AppDesign.pagePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppDesign.pageBackground)

        case .fill:
            content()
                .padding(AppDesign.pagePadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AppDesign.pageBackground)
        }
    }
}

struct PageStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.pageStackSpacing) {
            content()
        }
    }
}

/// List page: top toolbar + body that expands to fill window height.
struct ListPageScaffold<Toolbar: View, Body: View>: View {
    @ViewBuilder var toolbar: () -> Toolbar
    @ViewBuilder var bodyContent: () -> Body

    var body: some View {
        PageContainer(layout: .fill) {
            VStack(spacing: 16) {
                toolbar()
                    .frame(maxWidth: AppDesign.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                bodyContent()
                    .frame(maxWidth: AppDesign.contentMaxWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

extension View {
    func appPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Gate an irreversible or remote-writing action behind a confirmation dialog.
    ///
    /// `pending` carries whatever the action needs: assigning it opens the dialog, and both
    /// buttons clear it again. A toggle can drive its own `isOn` getter from `pending` so a
    /// cancel snaps the switch back without extra state.
    func confirmDestructive<Item>(
        _ pending: Binding<Item?>,
        title: String,
        confirmLabel: @escaping (Item) -> String,
        message: @escaping (Item) -> String,
        action: @escaping (Item) -> Void
    ) -> some View {
        confirmationDialog(
            title,
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let item = pending.wrappedValue {
                Button(confirmLabel(item), role: .destructive) {
                    pending.wrappedValue = nil
                    action(item)
                }
            }
            Button("取消", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            if let item = pending.wrappedValue {
                Text(message(item))
            }
        }
    }
}
