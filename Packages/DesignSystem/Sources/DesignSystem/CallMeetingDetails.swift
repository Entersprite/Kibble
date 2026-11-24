import ChatKit
import SwiftUI

@MainActor
public struct CallMeetingDetails {
    public let id: UUID
    let url: URL
    let dialIn: CallDialIn?
    let alternateDialIns: [CallDialIn]
    let attachments: [CallAgendaAttachment]
    let copy: (CallDialIn?) -> Void
    let openPhoneNumbers: (() -> Void)?
    let openAttachment: (CallAgendaAttachment) -> Void

    public init(
        id: UUID, url: URL, dialIn: CallDialIn?, alternateDialIns: [CallDialIn] = [],
        attachments: [CallAgendaAttachment] = [], copy: @escaping (CallDialIn?) -> Void,
        openPhoneNumbers: (() -> Void)? = nil,
        openAttachment: @escaping (CallAgendaAttachment) -> Void = { _ in }
    ) {
        self.id = id
        self.url = url
        self.dialIn = dialIn
        self.alternateDialIns = alternateDialIns
        self.attachments = attachments
        self.copy = copy
        self.openPhoneNumbers = openPhoneNumbers
        self.openAttachment = openAttachment
    }
}

struct CallMeetingDetailsPopover: ViewModifier {
    let details: CallMeetingDetails?
    @Binding var request: UUID?

    func body(content: Content) -> some View {
        content.popover(isPresented: isPresented, arrowEdge: .top) {
            if let details, request == details.id {
                CallMeetingDetailsContent(details: details).id(details.id)
            }
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { request != nil && request == details?.id },
            set: {
                if !$0 {
                    request = nil
                }
            }
        )
    }
}

struct CallMeetingDetailsContent: View {
    let details: CallMeetingDetails
    @Environment(\.locale) private var locale
    @State private var selectedDialIn: CallDialIn?

    private var numbers: [CallDialIn] {
        [details.dialIn].compactMap(\.self) + details.alternateDialIns
    }

    private var activeDialIn: CallDialIn? {
        if let selectedDialIn, numbers.contains(selectedDialIn) {
            return selectedDialIn
        }
        return numbers.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Details").font(.headline).accessibilityAddTraits(.isHeader)
            // The whole link stays selectable; a long one breaks in the middle.
            Text(details.url.absoluteString)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("Meeting link")
                .accessibilityValue(details.url.absoluteString)
            if let dialIn = activeDialIn {
                dialInRows(dialIn)
            }
            if let openPhoneNumbers = details.openPhoneNumbers {
                Button(
                    activeDialIn == nil ? "View Phone Numbers" : "More Phone Numbers",
                    action: openPhoneNumbers
                )
                .buttonStyle(.link)
                .accessibilityHint("Opens in your browser")
            }
            if activeDialIn != nil || details.openPhoneNumbers != nil {
                Button("Copy Joining Info", systemImage: "doc.on.doc") { details.copy(activeDialIn) }
            } else {
                Button("Copy Meeting Link", systemImage: "link") { details.copy(nil) }
            }
            if !details.attachments.isEmpty {
                Divider()
                Text("Attachments").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if details.attachments.count > 3 {
                    ScrollView { attachmentRows }.frame(height: 144)
                } else {
                    attachmentRows
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding()
    }

    private func dialInRows(_ dialIn: CallDialIn) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Phone").foregroundStyle(.secondary)
                if numbers.count > 1 {
                    Picker(
                        "Phone number",
                        selection: Binding(get: { activeDialIn }, set: { selectedDialIn = $0 })
                    ) {
                        ForEach(numbers, id: \.self) { number in
                            Text(numberLabel(number)).tag(Optional(number))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else {
                    Text(dialIn.phoneNumber).textSelection(.enabled)
                }
            }
            GridRow {
                Text("PIN").foregroundStyle(.secondary)
                Text(dialIn.pin).monospacedDigit().textSelection(.enabled)
            }
        }
    }

    private func numberLabel(_ number: CallDialIn) -> String {
        var label = number.phoneNumber
        if let regionCode = number.regionCode,
           let region = locale.localizedString(forRegionCode: regionCode) {
            label = String(localized: "\(label) (\(region))")
        }
        if numbers.contains(where: { $0.phoneNumber == number.phoneNumber && $0.pin != number.pin }) {
            label = String(localized: "\(label), PIN \(number.pin)")
        }
        return label
    }

    private var attachmentRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(details.attachments) { attachment in
                Button {
                    details.openAttachment(attachment)
                } label: {
                    Label {
                        (attachment.title.map(Text.init(verbatim:)) ?? Text("Attachment"))
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .buttonStyle(.link)
                .accessibilityHint("Opens in your browser")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
