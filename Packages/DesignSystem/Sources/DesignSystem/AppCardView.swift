import ChatKit
import SwiftUI

/// A Chat app's card under the bubble (links spec §7.4): a bordered box with
/// the header, then the sections, separated by dividers. Links and buttons
/// open through the transcript's `LinkPolicy`. An empty card - one the bridge
/// could map nothing from - is a note, never an empty box.
///
/// The card declares its corners as its `containerShape`, so a picture in it
/// rounds concentrically with them (`ConcentricRectangle`).
struct AppCardView: View {
    static let maxWidth: CGFloat = 420
    static let cornerRadius: CGFloat = 14
    /// The least a picture in a card rounds a corner far from the card's.
    static let pictureMinimumCorner: CGFloat = 8
    let card: AppCard
    let load: ((URL) async throws -> Data)?
    var perform: (@MainActor (AppCardAction) async throws -> AppCardActionResult)?

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
                if card.actions?.isEmpty == false || card.interactionFallback != nil {
                    Divider()
                    AppCardControls(card: card, perform: perform).id(card).padding(12)
                }
            }
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.quaternary))
            .containerShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
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
                .frame(width: 32, height: 32)
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

    /// A row with a link is a button that opens it, with the link as its
    /// tooltip; a row without one is plain content with no tooltip. Its own
    /// button stays outside, so it is never a button inside a button.
    private func decorated(_ row: AppCard.Decorated) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let link = row.link {
                Button { openURL(link) } label: {
                    decoratedContent(row).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(link.absoluteString)
                .accessibilityAddTraits(.isLink)
            } else {
                decoratedContent(row)
            }
            if let button = row.button {
                CardButtons(buttons: [button])
            }
        }
    }

    private func decoratedContent(_ row: AppCard.Decorated) -> some View {
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
                .frame(width: 24, height: 24)
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
        }
    }

    /// A picture with a link opens it as a button does, with the link as its
    /// tooltip; one without is only a picture.
    @ViewBuilder private func image(_ picture: AppCard.Picture) -> some View {
        if let load {
            RemoteImageView(url: picture.url, load: load) { phase in
                if let link = picture.link {
                    Button { openURL(link) } label: { pictureFrame(picture, phase: phase) }
                        .buttonStyle(.plain)
                        .help(link.absoluteString)
                        .accessibilityAddTraits(.isLink)
                } else {
                    pictureFrame(picture, phase: phase)
                }
            }
        }
    }

    private func pictureFrame(_ picture: AppCard.Picture, phase: RemoteImagePhase) -> some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(CardImageLayout.aspect(picture.aspectRatio), contentMode: .fit)
            .overlay {
                if case let .loaded(image) = phase {
                    Image(image, scale: 1, label: Text(picture.altText ?? ""))
                        .resizable()
                        .scaledToFit()
                }
            }
            .clipShape(ConcentricRectangle(corners: .concentric(minimum: .fixed(AppCardView
                    .pictureMinimumCorner))))
    }
}

enum CardImageLayout {
    static func aspect(_ declared: Double?) -> Double {
        guard let declared, declared.isFinite, declared > 0 else { return 16.0 / 9.0 }
        return declared
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
