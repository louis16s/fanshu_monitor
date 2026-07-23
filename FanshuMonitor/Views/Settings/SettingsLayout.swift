import AppKit
import SwiftUI

struct SettingsPage<Content: View>: View {
    let content: Content
    let scrolls: Bool
    let showsScrollIndicators: Bool
    let sectionSpacing: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat

    init(
        scrolls: Bool = true,
        showsScrollIndicators: Bool = true,
        sectionSpacing: CGFloat = 18,
        topPadding: CGFloat = 26,
        bottomPadding: CGFloat = 30,
        @ViewBuilder content: () -> Content
    ) {
        self.scrolls = scrolls
        self.showsScrollIndicators = showsScrollIndicators
        self.sectionSpacing = sectionSpacing
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.vertical, showsIndicators: showsScrollIndicators) {
                    pageContent
                }
            } else {
                pageContent
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            content
        }
        .padding(.top, topPadding)
        .padding(.horizontal, 34)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SettingsGroup<Content: View>: View {
    var title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }

            VStack(spacing: 0) {
                content
            }
            .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.22), lineWidth: 1)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let accessory: Accessory

    init(title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.82)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 16)

            accessory
                .frame(minWidth: 112, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, subtitle == nil ? 11 : 12)
        .frame(minHeight: subtitle == nil ? 46 : 62)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator.opacity(0.48))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

struct SettingsIconHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    let footnote: String
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        footnote: String,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footnote = footnote
        self.accessory = accessory()
    }

    var body: some View {
        let header = HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            accessory
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)

        if #available(macOS 26, *) {
            GlassEffectContainer {
                header
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        } else {
            header
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
