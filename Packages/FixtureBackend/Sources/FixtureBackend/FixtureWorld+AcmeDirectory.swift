import ChatKit
import Foundation

public extension FixtureWorld {
    /// Three invented people outside every Acme conversation, so
    /// `--backend=fixture` can show the `@` list's directory section and an
    /// invite (mention non-members spec §3.6). Not part of `acme` itself:
    /// the world's own snapshot, and every test that counts it, is unchanged.
    static let acmeDirectory: [Member] = [
        Member(
            id: Member.ID("acme-dir-1"),
            kind: .human,
            displayName: "Olive Outfield",
            email: "olive@example.invalid"
        ),
        Member(
            id: Member.ID("acme-dir-2"),
            kind: .human,
            displayName: "Oscar Otherton",
            email: "oscar@example.invalid"
        ),
        Member(
            id: Member.ID("acme-dir-3"),
            kind: .human,
            displayName: "Nadia Nearby",
            email: "nadia@example.invalid"
        )
    ]
}
