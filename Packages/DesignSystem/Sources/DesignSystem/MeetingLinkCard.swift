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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Self.title(for: link, in: text), systemImage: "video")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(12)
        .frame(maxWidth: LinkCardLayout.width, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        Button("Join with Kibble", systemImage: "video") { join?(link.url) }
            .buttonStyle(.borderedProminent)
            .disabled(join == nil)
        Link(destination: link.url) {
            Label("Open in Browser", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(.bordered)
        // This explicit choice bypasses the transcript's native-Join routing.
        .environment(\.openURL, LinkPolicy.openURLAction(blocking: blockedHosts))
    }
}
