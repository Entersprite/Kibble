import SwiftUI

/// A symbol at the start of a sidebar row, in the secondary color.
///
/// Every symbol is fitted into the same square (`SidebarRowPicture.symbol`),
/// so a wide one, such as Threads' two bubbles, is drawn no larger than
/// Search's magnifier. The square is centered in the column a conversation's
/// picture takes, so every row's name starts at the same place.
///
/// The color is a concrete `Color`, never a hierarchical style. Measured on
/// macOS 27 in a sidebar `List`: with the key window's appearance, a symbol
/// in a `Label`'s icon slot drawn with `.secondary`, `.primary` or no style
/// at all came out black - invisible on a dark sidebar, harsh on a light
/// one - while the window was in front, and correctly gray behind. Only a
/// concrete color (or a tint) drew the same in both.
struct SidebarSymbol: View {
    let name: String
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        let side = SidebarRowPicture.symbol(rowSize)
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: side, height: side)
            .foregroundStyle(Color.secondary)
            .frame(width: SidebarRowPicture.diameter(rowSize))
    }
}

/// A sidebar row's symbol and name, laid out as a conversation's picture and
/// name are. A plain stack rather than a `Label`: the sidebar sizes a
/// `Label`'s icon by its own rules, which made the symbols larger than the
/// conversations' and set the names off by two points.
struct SidebarSymbolTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            SidebarSymbol(name: symbol)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
        }
    }
}
