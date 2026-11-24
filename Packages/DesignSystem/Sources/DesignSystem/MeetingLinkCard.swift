import ChatKit
import SwiftUI

extension EnvironmentValues {
    @Entry var meetingLinkHosts: Set<String> = []
    @Entry var joinMeetingLink: ((URL) -> Void)?
}

/// Uses message metadata only; displaying a card never resolves or joins a meeting.
struct MeetingLinkCard: View {
    let link: MessageLink
    var text = ""
    @Environment(\.joinMeetingLink) private var join
    @Environment(\.internalLinkHosts) private var blockedHosts

    static func title(for link: MessageLink, in text: String) -> String {
        let title = link.preview?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, !title.contains("://") {
            return title
        }
        if let start = link.start, let length = link.length,
           let range = MessageFormat(style: "", start: start, length: length).range(in: text) {
            let label = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, label != link.url.absoluteString, !label.contains("://"),
               !label.localizedCaseInsensitiveContains(link.url.host() ?? "") {
                return label
            }
        }
        return "Meeting"
    }

    /// A link card's look (`LinkPreviewCard`): the name beside a glyph, where
    /// it leads under it, then the two ways in as small buttons with words
    /// only. They sit side by side, or one over the other in a narrow bubble.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: link, in: text))
                        .font(.callout.weight(.semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let domain = LinkCardLayout.domain(for: link) {
                        Text(domain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: LinkCardLayout.width, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
        .help(link.url.absoluteString)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        // Hidden where the host joins no meetings, rather than left disabled.
        if let join {
            Button("Join with Kibble") { join(link.url) }
                .buttonStyle(.borderedProminent)
        }
        Link("Open in Browser", destination: link.url)
            .buttonStyle(.bordered)
            // This explicit choice bypasses the transcript's native-Join routing.
            .environment(\.openURL, LinkPolicy.openURLAction(blocking: blockedHosts))
    }
}
