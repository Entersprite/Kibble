import ChatAPI
import ChatKit
import Testing
@testable import AppCore

struct AccountLabelsTests {
    @Test func organizationMustBeStatedAndCollisionsUseTheFullIdentity() {
        let first = account(
            "a",
            email: "first@example.invalid",
            organization: .managed(domain: "example.invalid")
        )
        let second = account(
            "b",
            email: "second@example.invalid",
            organization: .managed(domain: "EXAMPLE.invalid")
        )
        let labels = AccountLabels.labels(for: [first, second])
        #expect(labels[first.id] == "first@example.invalid")
        #expect(labels[second.id] == "second@example.invalid")
        let unstated = account("c", email: "third@example.invalid")
        #expect(AccountLabels.labels(for: [unstated])[unstated.id] == "third@example.invalid")
    }

    @Test func personalAndUnknownOrganizationsStayDistinctWithoutInferringDomains() {
        let personal = account("a", email: "first@example.invalid", organization: .personal)
        let other = account("b", email: "second@example.invalid", organization: .personal)
        #expect(AccountLabels.labels(for: [personal])[personal.id] == "Personal")
        #expect(AccountLabels.labels(for: [personal, other])[personal.id] == "first@example.invalid")
        let unknown = account(
            "c",
            email: "third@example.invalid",
            organization: .unknown(type: "future", payload: .object([:]))
        )
        #expect(AccountLabels.labels(for: [unknown])[unknown.id] == "third@example.invalid")
    }

    @Test func missingEmailsFallBackToNameThenServiceLabel() {
        let named = account("a", email: nil)
        #expect(AccountLabels.labels(for: [named])[named.id] == "Alex")
        let legacy = AccountSummary(
            id: .init("b"),
            selfID: .init("self"),
            label: "Account",
            connection: .idle
        )
        #expect(AccountLabels.labels(for: [legacy])[legacy.id] == "Account")
    }

    private func account(
        _ id: String,
        email: String?,
        organization: AccountOrganization = .unstated
    ) -> AccountSummary {
        AccountSummary(
            id: .init(id),
            selfID: .init("self"),
            label: "Account",
            connection: .idle,
            profile: AccountProfile(displayName: "Alex", email: email, organization: organization)
        )
    }
}
