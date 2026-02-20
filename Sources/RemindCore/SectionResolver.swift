import Foundation
import SQLite3

/// Reads section data from the Reminders CoreData SQLite store.
/// Degrades gracefully (returns empty map) when the database is unavailable.
public enum SectionResolver {
  private static let sqliteBusyTimeoutMs: Int32 = 1_500

  /// Builds a mapping of EventKit calendarItemIdentifier → section display name.
  /// Opens the database read-only; returns `[:]` on any failure.
  public static func resolve() -> [String: String] {
    guard let dbPath = findDatabase() else { return [:] }

    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      return [:]
    }
    defer { sqlite3_close(db) }

    // Reduce flaky failures while Reminders is concurrently writing WAL pages.
    sqlite3_busy_timeout(db, sqliteBusyTimeoutMs)

    let sections = querySections(db: db!)
    if sections.isEmpty { return [:] }

    let reminderMap = queryReminderIdentifiers(db: db!)
    let memberships = queryMemberships(db: db!)

    var result: [String: String] = [:]
    for (reminderCK, sectionCK) in memberships {
      guard let sectionName = sections[sectionCK],
        let ekID = reminderMap[reminderCK]
      else { continue }
      result[ekID] = sectionName
    }
    return result
  }

  // MARK: - Private

  private static func findDatabase() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let storesDir =
      "\(home)/Library/Group Containers/group.com.apple.reminders/Container_v1/Stores"
    return newestReadableDataStore(in: storesDir)
  }

  /// Returns the newest readable Reminders store, preferring `Data-*.sqlite` files.
  static func newestReadableDataStore(in storesDir: String, fileManager: FileManager = .default) -> String? {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: storesDir) else {
      return nil
    }

    func pickNewest(from fileNames: [String]) -> String? {
      var bestPath: String?
      var bestModified = Date.distantPast

      for file in fileNames {
        let path = "\(storesDir)/\(file)"
        guard fileManager.isReadableFile(atPath: path) else { continue }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        if modified > bestModified {
          bestModified = modified
          bestPath = path
        }
      }

      return bestPath
    }

    let remindersStores = contents.filter { $0.hasPrefix("Data-") && $0.hasSuffix(".sqlite") }
    if let newestRemindersStore = pickNewest(from: remindersStores) {
      return newestRemindersStore
    }

    let fallbackStores = contents.filter { $0.hasSuffix(".sqlite") }
    return pickNewest(from: fallbackStores)
  }

  /// Section CK identifier → display name.
  private static func querySections(db: OpaquePointer) -> [String: String] {
    let sql = "SELECT ZCKIDENTIFIER, ZDISPLAYNAME FROM ZREMCDBASESECTION"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var map: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let ckRaw = sqlite3_column_text(stmt, 0),
        let nameRaw = sqlite3_column_text(stmt, 1)
      else { continue }

      let ck = String(cString: ckRaw)
      guard ck.isEmpty == false else { continue }

      let name = String(cString: nameRaw)
      map[ck] = name
    }
    return map
  }

  /// Reminder CK identifier → EventKit calendarItemIdentifier.
  private static func queryReminderIdentifiers(db: OpaquePointer) -> [String: String] {
    let sql = """
      SELECT ZCKIDENTIFIER, ZDACALENDARITEMUNIQUEIDENTIFIER \
      FROM ZREMCDREMINDER \
      WHERE ZDACALENDARITEMUNIQUEIDENTIFIER IS NOT NULL
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var map: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let ckRaw = sqlite3_column_text(stmt, 0),
        let ekRaw = sqlite3_column_text(stmt, 1)
      else { continue }

      let ck = String(cString: ckRaw)
      let ek = String(cString: ekRaw)
      guard ck.isEmpty == false, ek.isEmpty == false else { continue }

      map[ck] = ek
    }
    return map
  }

  /// Reminder CK identifier → section CK identifier (from membership JSON blobs on lists).
  private static func queryMemberships(db: OpaquePointer) -> [String: String] {
    let sql = """
      SELECT ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA \
      FROM ZREMCDBASELIST \
      WHERE ZMEMBERSHIPSOFREMINDERSINSECTIONSASDATA IS NOT NULL
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
    defer { sqlite3_finalize(stmt) }

    var map: [String: String] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
      let length = Int(sqlite3_column_bytes(stmt, 0))
      let data = Data(bytes: blob, count: length)
      parseMembershipBlob(data, into: &map)
    }
    return map
  }

  private static func parseMembershipBlob(_ data: Data, into map: inout [String: String]) {
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let memberships = json["memberships"] as? [[String: Any]]
    else { return }

    for entry in memberships {
      guard let memberID = entry["memberID"] as? String,
        let groupID = entry["groupID"] as? String,
        memberID.isEmpty == false,
        groupID.isEmpty == false
      else { continue }
      map[memberID] = groupID
    }
  }
}
