import AppCore
import ChatAPI
import ChatKit
import Foundation

/// Display-only client cache, separate from replicas erased at sign-out. It
/// never fetches a URL; bytes arrive from an authorized session image loader.
@MainActor
final class AccountProfilePhotoCache {
    private struct Entry: Codable {
        let account: ConnectedAccountID
        let identity: Member.ID
        let photo: AccountProfilePhoto
    }

    private let directory: URL
    private var accounts: [ConnectedAccountID: AccountSummary] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func update(_ accounts: [AccountSummary]) {
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    func prepare(_ accounts: [AccountSummary]) throws {
        update(accounts)
        let retained = Set(accounts.filter { !$0.isRemoving }.map { file($0.id).lastPathComponent })
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
            where !retained.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func eraseIfRemoved(_ account: AccountSummary) throws {
        guard accounts[account.id] == nil || accounts[account.id]?.isRemoving == true else { return }
        do {
            try FileManager.default.removeItem(at: file(account.id))
        } catch CocoaError.fileNoSuchFile { return }
    }

    func load(_ accounts: [AccountSummary]) -> [ConnectedAccountID: AccountProfilePhoto] {
        update(accounts)
        var photos: [ConnectedAccountID: AccountProfilePhoto] = [:]
        for account in accounts where !account.isRemoving {
            let url = file(account.id)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= AccountProfilePhoto.maximumBytes * 2,
                  let data = try? read(url),
                  let entry = try? ServiceCodec.decode(Entry.self, from: data),
                  entry.account == account.id, entry.identity == account.selfID,
                  let photo = AccountProfilePhoto(url: entry.photo.url, data: entry.photo.data)
            else { continue }
            photos[account.id] = photo
        }
        return photos
    }

    func save(_ photo: AccountProfilePhoto, for account: AccountSummary) {
        guard let current = accounts[account.id], current.selfID == account.selfID,
              current.revision == account.revision, current.isEnabled, !current.isRemoving,
              current.authenticationState == nil,
              AccountProfilePhoto(url: photo.url, data: photo.data) != nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = Entry(account: account.id, identity: account.selfID, photo: photo)
            try ServiceCodec.encode(entry).write(to: file(account.id), options: .atomic)
        } catch { /* Display caching must not interrupt chat or sign-in. */ }
    }

    private func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AccountProfilePhoto.maximumBytes * 2 + 1) ?? Data()
        guard data.count <= AccountProfilePhoto.maximumBytes * 2 else { throw ServiceFailure.frameTooLarge }
        return data
    }

    private func file(_ id: ConnectedAccountID) -> URL {
        let name = Data(id.rawValue.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
}
