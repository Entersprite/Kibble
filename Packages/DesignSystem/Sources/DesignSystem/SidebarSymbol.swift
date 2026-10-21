import SwiftUI

/// A symbol in a sidebar row's `Label` icon slot, in the secondary color.
///
/// The color is a concrete `Color`, never a hierarchical style. Measured on
/// macOS 27 in a sidebar `List`: with the key window's appearance, a symbol
/// in a `Label`'s icon slot drawn with `.secondary`, `.primary` or no style
/// at all came out black - invisible on a dark sidebar, harsh on a light
/// one - while the window was in front, and correctly gray behind. Only a
/// concrete color (or a tint) drew the same in both.
struct SidebarSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(Color.secondary)
    }
}

extension Label where Title == Text, Icon == SidebarSymbol {
    /// A sidebar row's label with its symbol drawn by `SidebarSymbol`.
    init(_ title: String, sidebarSymbol name: String) {
        self.init {
            Text(title)
        } icon: {
            SidebarSymbol(name: name)
        }
    }
}
