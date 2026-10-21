import ChatKit
import SwiftUI

/// Settings › Sidebar, built like the other panes: a grouped form. The
/// sections first, each with a switch and a place in the order, then one
/// group per shown section for how it sorts and how much of it shows.
/// Favorites is not in the order: it always comes first and is never hidden.
public struct SidebarSettingsPane: View {
    let preferences: SidebarPreferences
    let update: (SidebarPreferences) -> Void

    public init(preferences: SidebarPreferences, update: @escaping (SidebarPreferences) -> Void) {
        self.preferences = preferences
        self.update = update
    }

    private var sections: [SidebarSectionPreference] {
        preferences.orderedSections
    }

    public var body: some View {
        Form {
            Section {
                ForEach(sections) { section in
                    order(section)
                }
                .onMove { source, destination in
                    update(SidebarSectionOrder.moving(
                        preferences,
                        fromOffsets: source,
                        toOffset: destination
                    ))
                }
            } header: {
                Text("Sections")
            } footer: {
                Text("Turn off a section to hide it. To change the order, drag a section or use its menu. "
                    + "Favorites always comes first.")
            }
            ForEach(preferences.displaySections.filter(\.isVisible)) { section in
                Section(section.title) {
                    Picker("Sort By", selection: Binding(
                        get: { section.sort },
                        set: { change(SidebarSortTitles.changing(section, to: $0)) }
                    )) {
                        ForEach([SidebarSortOrder.activity, .name], id: \.self) {
                            Text(SidebarSortTitles.sort($0)).tag($0)
                        }
                    }
                    Picker("Order", selection: Binding(
                        get: { section.sortsAscending },
                        set: { var changed = section; changed.isAscending = $0; change(changed) }
                    )) {
                        ForEach([false, true], id: \.self) { ascending in
                            Text(SidebarSortTitles.order(section.sort, ascending: ascending)).tag(ascending)
                        }
                    }
                    if section.id != "favorites" {
                        LabeledContent("Conversations Shown") {
                            SidebarLimitField(title: section.title, value: section.maximumItems) {
                                var changed = section
                                changed.maximumItems = $0
                                change(changed)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// A section's row: its name, its menu, and its switch. The menu is the
    /// keyboard's way to reorder, beside the drag and the accessibility actions.
    private func order(_ section: SidebarSectionPreference) -> some View {
        let place = SettingsOrder.place(of: section.id, in: sections)
        let move = { (direction: SettingsMove) in
            if let next = SidebarSectionOrder.moving(section.id, direction, in: preferences) {
                update(next)
            }
        }
        return HStack(spacing: 6) {
            Text(section.title)
            Spacer()
            Menu {
                SettingsMoveMenuItems(place: place, move: move)
            } label: {
                Label("\(section.title) Options", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!place.isReorderable)
            Toggle("Show \(section.title)", isOn: Binding(
                get: { section.isVisible },
                set: { var changed = section; changed.isVisible = $0; change(changed) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .padding(.leading, 6)
        }
        .settingsMoveActions(place, move: move)
        .contextMenu { SettingsMoveMenuItems(place: place, move: move) }
    }

    private func change(_ section: SidebarSectionPreference) {
        update(preferences.updating(section))
    }
}

/// The sidebar's section order as Settings changes it: every move goes
/// through `SettingsOrder` among the reorderable sections, and Favorites is
/// put back first, wherever it was stored.
enum SidebarSectionOrder {
    /// `preferences` with the reorderable sections in `rows`' order.
    static func ordering(
        _ preferences: SidebarPreferences, as rows: [SidebarSectionPreference]
    ) -> SidebarPreferences {
        var next = preferences
        next.sections = [preferences.favoritesSection] + rows
        return next
    }

    /// One section a place up or down; `nil` at an end, and for Favorites,
    /// which is not in the order.
    static func moving(
        _ id: String, _ move: SettingsMove, in preferences: SidebarPreferences
    ) -> SidebarPreferences? {
        SettingsOrder.moving(id, move, in: preferences.orderedSections).map { ordering(preferences, as: $0) }
    }

    /// A drag among the reorderable sections.
    static func moving(
        _ preferences: SidebarPreferences, fromOffsets source: IndexSet, toOffset destination: Int
    ) -> SidebarPreferences {
        ordering(
            preferences,
            as: SettingsOrder.moving(preferences.orderedSections, fromOffsets: source, toOffset: destination)
        )
    }
}

/// A count typed or stepped, like the number fields in System Settings. The
/// field keeps its text until Return or a click elsewhere, and a value that
/// is not a positive whole number goes back to the last good one.
struct SidebarLimitField: View {
    let title: String
    let value: Int
    let change: (Int) -> Void

    static let range = 1 ... 999

    var body: some View {
        HStack(spacing: 4) {
            TextField(
                "Conversations Shown in \(title)",
                value: Binding(get: { value }, set: { typed in
                    if Self.range.contains(typed) {
                        change(typed)
                    }
                }),
                format: .number
            )
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            Stepper(
                "Conversations Shown in \(title)",
                value: Binding(get: { value }, set: { change($0) }),
                in: Self.range
            )
            .labelsHidden()
        }
    }
}

/// The last row of a sidebar section, opening the whole list: an ellipsis
/// and plain words in the secondary color, so it reads as a way on rather
/// than as one more conversation.
struct SidebarSeeAllRow: View {
    let title: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            // A row's 20-point picture column and 8-point gap, so the words
            // line up with the conversations' names.
            HStack(spacing: 8) {
                Image(systemName: "ellipsis")
                    .frame(width: 20)
                Text("See All")
                Spacer(minLength: 4)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See All \(title)")
    }
}

/// A section header's menu, shown on hover by `sectionActions`: how the
/// section sorts, hiding it, and the rest in Settings.
struct SidebarSectionMenu: View {
    let id: String
    let preferences: SidebarPreferences
    let update: (SidebarPreferences) -> Void
    var showSettings: (() -> Void)?

    var body: some View {
        let section = preferences.section(id)
        Menu {
            SidebarSortMenuItems(section: section) { update(preferences.updating($0)) }
            Divider()
            if id != "favorites" {
                Button("Hide \(section.title)") {
                    var hidden = section
                    hidden.isVisible = false
                    update(preferences.updating(hidden))
                }
            }
            if let showSettings {
                Button("Sidebar Settings…", action: showSettings)
            }
        } label: {
            // A borderless button draws its own label in the primary color,
            // ignoring any style here, so it read as white beside the system's
            // secondary disclosure arrow. A plain button draws this label.
            Label("\(section.title) Options", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(.secondary)
                // The trailing padding is the gap to the disclosure arrow.
                .padding(.leading, 3)
                .padding(.trailing, 7)
                // A click anywhere else on the header collapses the section,
                // and the dots alone are about 8 pt tall in a 19-pt header, so
                // a slight miss collapsed it. The target reaches past the label
                // to the header's full height and up to the arrow, whose own
                // button sits above it and still wins where the two overlap.
                .contentShape(Rectangle().inset(by: -8))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Section Options")
    }
}
