import ChatKit
import SwiftUI

/// A Chat app's card under the bubble (links spec §7.4): a bordered box with
/// the header, then the sections, separated by dividers. Links and buttons
/// open through the transcript's `LinkPolicy`. An empty card - one the bridge
/// could map nothing from - is a note, never an empty box.
struct AppCardView: View {
    static let maxWidth: CGFloat = 420
    let card: AppCard
    let load: ((URL) async throws -> Data)?

    var body: some View {
        if card.isEmpty {
            Text("This app message can't be shown here.")
                .font(.callout.italic())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if let header = card.header {
                    CardHeaderView(header: header, load: load).padding(12)
                }
                ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 || card.header != nil {
                        Divider()
                    }
                    CardSectionView(section: section, load: load).padding(12)
                }
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        }
    }
}

private struct CardHeaderView: View {
    let header: AppCard.Header
    let load: ((URL) async throws -> Data)?

    var body: some View {
        HStack(spacing: 10) {
            if let url = header.imageURL, let load {
                RemoteImageView(url: url, load: load) { phase in
                    if case let .loaded(image) = phase {
                        Image(image, scale: 1, label: Text(header.title.plainText))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(
                                header
                                    .circularImage ? AnyShape(Circle()) :
                                    AnyShape(RoundedRectangle(cornerRadius: 6))
                            )
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(RichTextAttributes.attributed(header.title)).font(.headline)
                if let subtitle = header.subtitle {
                    Text(RichTextAttributes.attributed(subtitle)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CardSectionView: View {
    let section: AppCard.Section
    let load: ((URL) async throws -> Data)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = section.header {
                Text(RichTextAttributes.attributed(header)).font(.subheadline.weight(.semibold))
            }
            ForEach(Array(section.widgets.enumerated()), id: \.offset) { _, widget in
                CardWidgetView(widget: widget, load: load)
            }
        }
    }
}

private struct CardWidgetView: View {
    let widget: AppCard.Widget
    let load: ((URL) async throws -> Data)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch widget {
        case let .text(text):
            Text(RichTextAttributes.attributed(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .decorated(row):
            decorated(row)
        case let .image(picture):
            image(picture)
        case let .buttons(buttons):
            CardButtons(buttons: buttons)
        case .divider:
            Divider()
        case .unknown:
            EmptyView()
        }
    }

    private func decorated(_ row: AppCard.Decorated) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let icon = row.iconURL, let load {
                RemoteImageView(url: icon, load: load) { phase in
                    if case let .loaded(image) = phase {
                        Image(decorative: image, scale: 1).resizable().scaledToFit().frame(
                            width: 24,
                            height: 24
                        )
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if let top = row.top {
                    Text(RichTextAttributes.attributed(top)).font(.caption).foregroundStyle(.secondary)
                }
                Text(RichTextAttributes.attributed(row.content))
                if let bottom = row.bottom {
                    Text(RichTextAttributes.attributed(bottom)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let button = row.button {
                CardButtons(buttons: [button])
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let link = row.link {
                openURL(link)
            }
        }
        .help(row.link?.absoluteString ?? "")
    }

    @ViewBuilder private func image(_ picture: AppCard.Picture) -> some View {
        if let load {
            RemoteImageView(url: picture.url, load: load) { phase in
                if case let .loaded(image) = phase {
                    Image(image, scale: 1, label: Text(picture.altText ?? ""))
                        .resizable()
                        .aspectRatio(
                            picture.aspectRatio ?? Double(image.width) / Double(max(1, image.height)),
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            if let link = picture.link {
                                openURL(link)
                            }
                        }
                }
            }
        }
    }
}

/// A row of capsule buttons, wrapping to a column when the row does not fit.
private struct CardButtons: View {
    let buttons: [LinkButton]
    @Environment(\.openURL) private var openURL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    private var content: some View {
        ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
            Button(button.label) { openURL(button.url) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help(button.url.absoluteString)
        }
    }
}
