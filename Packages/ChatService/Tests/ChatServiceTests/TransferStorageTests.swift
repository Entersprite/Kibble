import ChatAPI
import ChatService
import ChatServiceStorage
import Foundation
import Testing

struct TransferStorageTests {
    let firstAccount = ConnectedAccountID("firstAccount")
    let secondAccount = ConnectedAccountID("secondAccount")
    let id = ServiceTransferID("opaque-transfer")

    func factory(budget: Int = 16) -> DirectoryTransferStorageFactory {
        DirectoryTransferStorageFactory(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            maximumReservedBytes: budget
        )
    }

    @Test func reservationIsSharedAcrossAccountsAndReleasedOnlyAfterCleanup() throws {
        let factory = factory(budget: 4)
        let first = try factory.open(firstAccount)
        let second = try factory.open(secondAccount)
        try first.create(id, maximumBytes: 4)
        #expect(throws: ServiceFailure.overloaded) { try second.create(id, maximumBytes: 1) }
        #expect(throws: ServiceFailure.ownerBusy) { try factory.open(firstAccount) }
        try first.append(Data([1, 2, 3, 4]), to: id, at: 0)
        let owned = try first.file(id, expectedBytes: 4)
        try first.close()
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        try second.create(id, maximumBytes: 4)
        try second.close()
    }

    @Test func actualByteBoundsOffsetsAndForeignHandlesAreEnforced() throws {
        let factory = factory()
        let first = try factory.open(firstAccount)
        let second = try factory.open(secondAccount)
        try first.create(id, maximumBytes: 4)
        try first.append(Data([1, 2]), to: id, at: 0)
        #expect(throws: ServiceFailure.operationConflict) {
            try first.append(Data([9]), to: id, at: 0)
        }
        #expect(throws: ServiceFailure.invalidRequest) {
            try first.append(Data([3, 4, 5]), to: id, at: 2)
        }
        #expect(throws: ServiceFailure.invalidRequest) { try first.read(id, at: -1, count: 1) }
        #expect(throws: ServiceFailure.invalidRequest) { try first.read(id, at: 0, count: 65537) }
        #expect(throws: ServiceFailure.transferExpired) { try second.read(id, at: 0, count: 2) }
        #expect(throws: ServiceFailure.operationConflict) { try first.file(id, expectedBytes: 4) }
        try first.append(Data([3, 4]), to: id, at: 2)
        #expect(try first.read(id, at: 1, count: 3) == Data([2, 3, 4]))
        #expect(try Data(contentsOf: first.file(id, expectedBytes: 4)) == Data([1, 2, 3, 4]))
        #expect(throws: ServiceFailure.operationConflict) { try first.create(id, maximumBytes: 4) }
        try first.close()
        try second.close()
    }

    @Test func closedWriterCannotRecreateOrMutateAReplacementSpool() throws {
        let factory = factory()
        let first = try factory.open(firstAccount)
        try first.create(id, maximumBytes: 4)
        try first.close()
        let replacement = try factory.open(firstAccount)
        try replacement.create(id, maximumBytes: 4)
        #expect(throws: ServiceFailure.accountDisabled) { try first.create(id, maximumBytes: 4) }
        #expect(throws: ServiceFailure.transferExpired) {
            try first.append(Data([1]), to: id, at: 0)
        }
        try first.close()
        #expect(throws: ServiceFailure.ownerBusy) { try factory.open(firstAccount) }
        try replacement.append(Data([2]), to: id, at: 0)
        #expect(try replacement.read(id, at: 0, count: 1) == Data([2]))
        try replacement.close()
    }

    @Test func abandonedFilesAreReclaimedUnderTheNextAccountWriter() throws {
        let factory = factory(budget: 4)
        let old = try abandon(factory)
        #expect(FileManager.default.fileExists(atPath: old.path))
        let reopened = try factory.open(firstAccount)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        try reopened.create(id, maximumBytes: 4)
        try reopened.append(Data([9]), to: id, at: 0)
        try reopened.close()
    }

    @Test func aNewFactoryChargesAbandonedDisabledAccountFilesUntilTheirOwnedCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = DirectoryTransferStorageFactory(directory: directory, maximumReservedBytes: 4)
        let abandoned = try abandon(original)
        let restarted = DirectoryTransferStorageFactory(directory: directory, maximumReservedBytes: 4)
        let other = try restarted.open(secondAccount)
        #expect(throws: ServiceFailure.overloaded) { try other.create(id, maximumBytes: 1) }
        try restarted.erase(firstAccount)
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        try other.create(id, maximumBytes: 4)
        try other.close()
    }

    @Test func maximumChunkIsWrittenWithoutPuttingItsBytesOrPathInMetadata() throws {
        let factory = factory(budget: 65536)
        let writer = try factory.open(firstAccount)
        try writer.create(id, maximumBytes: 65536)
        let data = Data(repeating: 255, count: 65536)
        try writer.append(data, to: id, at: 0)
        let file = try writer.file(id, expectedBytes: 65536)
        let payload = BeginUploadTransfer(
            operationID: ServiceOperationID("begin"), conversationID: .init("conversation"),
            metadata: UploadFileMetadata(
                name: "../chosen file",
                contentType: "image/png",
                byteSize: data.count
            )
        )
        let json = try String(decoding: ServiceCodec.encode(payload), as: UTF8.self)
        #expect(!json.contains(file.path))
        #expect(!json.contains(data.base64EncodedString()))
        #expect(file.lastPathComponent.hasPrefix("spool-"))
        #expect(try writer.read(id, at: 0, count: 65536) == data)
        try writer.close()
    }

    private func abandon(_ factory: DirectoryTransferStorageFactory) throws -> URL {
        let writer = try factory.open(firstAccount)
        try writer.create(id, maximumBytes: 4)
        try writer.append(Data([1, 2, 3, 4]), to: id, at: 0)
        return try writer.file(id, expectedBytes: 4)
    }
}
