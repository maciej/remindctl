import Foundation
import Testing

@testable import RemindCore

@MainActor
struct SectionResolverTests {
  @Test("Prefers newest readable Data-*.sqlite store")
  func picksNewestDataStore() throws {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: tempRoot) }

    let staleStore = tempRoot.appendingPathComponent("Data-stale.sqlite")
    let freshStore = tempRoot.appendingPathComponent("Data-fresh.sqlite")
    let fallbackStore = tempRoot.appendingPathComponent("Fallback.sqlite")

    fileManager.createFile(atPath: staleStore.path, contents: Data())
    fileManager.createFile(atPath: freshStore.path, contents: Data())
    fileManager.createFile(atPath: fallbackStore.path, contents: Data())

    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = Date(timeIntervalSince1970: 1_800_000_000)
    try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleStore.path)
    try fileManager.setAttributes([.modificationDate: newDate], ofItemAtPath: freshStore.path)

    let selected = SectionResolver.newestReadableDataStore(in: tempRoot.path)
    #expect(selected == freshStore.path)
  }
}
