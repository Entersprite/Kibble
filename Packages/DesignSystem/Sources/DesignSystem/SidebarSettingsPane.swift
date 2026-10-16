import ChatKit
import SwiftUI

public struct SidebarSettingsPane: View {
    let preferences: SidebarPreferences
    let update: (SidebarPreferences) -> Void

    public init(preferences: SidebarPreferences, update: @escaping (SidebarPreferences) -> Void) {
        self.preferences = preferences
        self.update = update
    }

    private func move(_ id: String, by step: Int) {
        var rows = preferences.orderedSections
        guard let index = rows.firstIndex(where: { $0.id == id }),
              rows.indices.contains(index + step) else { return }
        rows.swapAt(index, index + step)
        update(SidebarPreferences(sections: rows))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sidebar").font(.title2.bold())
            Text("Choose which sections appear and how many conversations each section shows.")
                .foregroundStyle(.secondary)
            List {
                ForEach(preferences.orderedSections) { section in
                    HStack {
                        VStack {
                            Button("Move Up", systemImage: "chevron.up") { move(section.id, by: -1) }
                                .disabled(preferences.orderedSections.first?.id == section.id)
                            Button("Move Down", systemImage: "chevron.down") { move(section.id, by: 1) }
                                .disabled(preferences.orderedSections.last?.id == section.id)
                        }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        SidebarPreferenceRow(section: section) { changed in
                            var next = preferences
                            next.update(changed)
                            update(next)
                        }
                    }
                }
                .onMove { source, destination in
                    var rows = preferences.orderedSections
                    rows.move(fromOffsets: source, toOffset: destination)
                    update(SidebarPreferences(sections: rows))
                }
            }
            Text("Drag sections to reorder them. Open full lists with See All… in each section.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct SidebarPreferenceRow: View {
    let section: SidebarSectionPreference
    let update: (SidebarSectionPreference) -> Void
    @State private var limit = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(section.title, isOn: Binding(
                get: { section.isVisible },
                set: { var next = section; next.isVisible = $0; update(next) }
            ))
            HStack {
                Picker("Sort", selection: Binding(
                    get: { section.sort },
                    set: { var next = section; next.sort = $0; update(next) }
                )) {
                    Text("Activity / Last Updated").tag(SidebarSortOrder.activity)
                    Text("Name").tag(SidebarSortOrder.name)
                }
                Picker("Order", selection: Binding(
                    get: { section.sortsAscending },
                    set: { var next = section; next.isAscending = $0; update(next) }
                )) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            }
            HStack {
                Text("Show")
                TextField("Maximum items", text: $limit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .onSubmit(saveLimit)
                    .onChange(of: limit) { saveLimit() }
                Text("items")
            }
            if Int(limit).map({ $0 > 0 }) != true {
                Text("Enter a positive whole number.").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 6)
        .onAppear { limit = String(section.maximumItems) }
        .onChange(of: section.maximumItems) { limit = String(section.maximumItems) }
    }

    private func saveLimit() {
        guard let value = Int(limit), value > 0, value != section.maximumItems else { return }
        var next = section
        next.maximumItems = value
        update(next)
    }
}

struct SidebarSectionMenu: View {
    let id: String
    let preferences: SidebarPreferences
    let update: (SidebarPreferences) -> Void
    var showSettings: (() -> Void)?

    var body: some View {
        Menu {
            if let section = preferences.orderedSections.first(where: { $0.id == id }) {
                Picker("Sort By", selection: Binding(
                    get: { section.sort },
                    set: { order in
                        var next = preferences
                        var changed = section
                        changed.sort = order
                        next.update(changed)
                        update(next)
                    }
                )) {
                    Text("Activity / Last Updated").tag(SidebarSortOrder.activity)
                    Text("Name").tag(SidebarSortOrder.name)
                }
                Picker("Order", selection: Binding(
                    get: { section.sortsAscending },
                    set: { ascending in
                        var next = preferences
                        var changed = section
                        changed.isAscending = ascending
                        next.update(changed)
                        update(next)
                    }
                )) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            }
            if let showSettings {
                Divider()
                Button("Sidebar Settings…", action: showSettings)
            }
        } label: {
            Label("Section Options", systemImage: "ellipsis").labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Section Options")
    }
}
