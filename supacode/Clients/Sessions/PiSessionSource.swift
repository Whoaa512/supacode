import Foundation
import SupacodeSettingsShared

actor PiSessionSource: SessionSource {
  private nonisolated struct Stamp: Codable, Equatable {
    var modified: Date
    var size: Int
  }

  private nonisolated struct CachedFile: Codable {
    var stamp: Stamp
    var summary: SessionSummary
  }

  private nonisolated struct Entry: Decodable {
    var type: String
    var id: String?
    var timestamp: String?
    var cwd: String?
    var name: String?
    var message: Message?

    nonisolated struct Message: Decodable {
      var role: String
      var content: Content?
    }

    nonisolated enum Content: Decodable {
      case text(String)
      case blocks([Block])

      init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
          self = .text(text)
          return
        }
        self = .blocks(try container.decode([Block].self))
      }

      var text: String {
        switch self {
        case .text(let text): return text
        case .blocks(let blocks):
          return blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: " ")
        }
      }
    }
  }

  private nonisolated struct Block: Decodable {
    var type: String
    var text: String?
  }

  private let root: URL
  private let cacheURL: URL
  private let chunkSize: Int
  private var cache: [String: CachedFile] = [:]
  private var cacheLoaded = false
  private(set) var parsedFileCount = 0
  private static let logger = SupaLogger("Sessions")

  init(root: URL, cacheURL: URL, chunkSize: Int = 64 * 1024) {
    self.root = root.standardizedFileURL
    self.cacheURL = cacheURL
    self.chunkSize = max(1, chunkSize)
  }

  func cachedSessions() -> [SessionSummary] {
    loadCacheIfNeeded()
    return SessionClassification.ordered(cache.values.map(\.summary))
  }

  private func loadCacheIfNeeded() {
    guard !cacheLoaded else { return }
    cacheLoaded = true
    cache = (try? JSONDecoder().decode([String: CachedFile].self, from: Data(contentsOf: cacheURL))) ?? [:]
  }

  nonisolated func resumeCommand(sessionID: String) -> String? {
    AgentResumeCommand.command(agent: .pi, sessionRef: sessionID)
  }

  func sessions() async throws -> [SessionSummary] {
    await Task.yield()
    loadCacheIfNeeded()
    let manager = FileManager.default
    do {
      _ = try manager.attributesOfItem(atPath: root.path)
    } catch CocoaError.fileReadNoSuchFile {
      cache = [:]
      persist()
      return []
    }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let directories = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
    let directoryPaths = Set(directories.map(\.path))
    var refreshed = cache.filter {
      directoryPaths.contains(URL(fileURLWithPath: $0.key).deletingLastPathComponent().path)
    }.mapValues { file in
      var unverified = file
      unverified.summary.isVerified = false
      return unverified
    }
    var failures = 0
    for directory in directories {
      guard let values = try? directory.resourceValues(forKeys: keys),
        values.isDirectory == true, values.isSymbolicLink != true
      else { continue }
      guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
      else { continue }
      let filePaths = Set(files.map(\.path))
      refreshed = refreshed.filter {
        URL(fileURLWithPath: $0.key).deletingLastPathComponent().path != directory.path || filePaths.contains($0.key)
      }
      for file in files where file.pathExtension == "jsonl" {
        guard let values = try? file.resourceValues(forKeys: keys),
          values.isRegularFile == true, values.isSymbolicLink != true
        else { continue }
        do {
          let before = try stamp(file)
          if let hit = cache[file.path], hit.stamp == before, hit.summary.isVerified {
            var verified = hit
            verified.summary.isVerified = true
            refreshed[file.path] = verified
            continue
          }
          parsedFileCount += 1
          guard let summary = try parse(file) else { continue }
          if try stamp(file) == before {
            refreshed[file.path] = CachedFile(stamp: before, summary: summary)
          }
        } catch {
          failures += 1
        }
      }
    }
    if failures > 0 { Self.logger.warning("Could not read \(failures) session files") }
    cache = refreshed
    persist()
    return SessionClassification.ordered(cache.values.map(\.summary))
  }

  private func stamp(_ url: URL) throws -> Stamp {
    let values = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let modified = values[.modificationDate] as? Date, let size = values[.size] as? Int else {
      throw CocoaError(.fileReadUnknown)
    }
    return Stamp(modified: modified, size: size)
  }

  private func persist() {
    let verified = cache.filter { $0.value.summary.isVerified }
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(verified).write(to: cacheURL, options: .atomic)
    } catch {
      Self.logger.warning("Could not persist session cache: \(error)")
    }
  }

  private func parse(_ url: URL) throws -> SessionSummary? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let decoder = JSONDecoder()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    var summary: SessionSummary?
    var firstLine = true
    var firstUser: String?
    var name: String?
    var pending = Data()

    func consume(_ line: Data) {
      if firstLine {
        firstLine = false
        guard let header = try? decoder.decode(Entry.self, from: line), header.type == "session",
          let id = header.id, AgentPresenceOSC.sanitizedSessionRef(id) != nil,
          let cwd = header.cwd, cwd.hasPrefix("/"), !Self.isTemporary(cwd),
          let timestamp = header.timestamp,
          let created = fractional.date(from: timestamp) ?? plain.date(from: timestamp)
        else { return }
        summary = SessionSummary(
          harness: .pi, sessionID: id, createdAt: created, cwd: cwd,
          title: "Untitled session", messageCount: 0, lastActivity: created)
        return
      }
      guard summary != nil else { return }
      let fields = Self.fields(line)
      if fields["type"] == "session_info" {
        if let entry = try? decoder.decode(Entry.self, from: line) { name = entry.name }
        return
      }
      guard fields["type"] == "message", line.last(where: { ![9, 13, 32].contains($0) }) == 125 else { return }
      summary?.messageCount += 1
      if let timestamp = fields["timestamp"],
        let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp),
        let previous = summary?.lastActivity, date > previous
      {
        summary?.lastActivity = date
      }
      guard firstUser == nil, fields["role"] == "user",
        let entry = try? decoder.decode(Entry.self, from: line), entry.message?.role == "user"
      else { return }
      firstUser = entry.message?.content?.text ?? ""
    }

    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
      let scanStart = pending.endIndex
      pending.append(chunk)
      var start = pending.startIndex
      for index in scanStart..<pending.endIndex where pending[index] == 10 {
        consume(Data(pending[start..<index]))
        start = index + 1
      }
      if start > pending.startIndex { pending.removeSubrange(pending.startIndex..<start) }
    }
    if !pending.isEmpty { consume(pending) }
    let title = Self.displayText(name ?? "")
    let fallback = Self.displayText(firstUser ?? "")
    summary?.title = !title.isEmpty ? title : (!fallback.isEmpty ? fallback : "Untitled session")
    return summary
  }

  private static func displayText(_ text: String) -> String {
    let cleaned = text.unicodeScalars.map {
      CharacterSet.controlCharacters.contains($0) ? " " : String($0)
    }.joined()
    return String(cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
  }

  static func isTemporary(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    return [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path].contains {
      candidate in
      ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"].contains {
        candidate == $0 || candidate.hasPrefix($0 + "/")
      }
    }
  }

  private static func stringEnd(_ data: Data, startingAt start: Int) -> Int {
    var index = start
    while index < data.endIndex {
      if data[index] == 34 { return index }
      index += data[index] == 92 ? 2 : 1
    }
    return data.endIndex
  }

  private static func fields(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    var depth = 0
    var index = data.startIndex
    var key: String?
    while index < data.endIndex {
      let byte = data[index]
      if byte == 123 || byte == 91 { depth += 1 }
      if byte == 125 || byte == 93 { depth -= 1 }
      guard byte == 34 else {
        index += 1
        continue
      }
      let start = index + 1
      index = Self.stringEnd(data, startingAt: start)
      guard index < data.endIndex else { break }
      if depth == 1 || depth == 2 {
        guard let value = String(bytes: data[start..<index], encoding: .utf8) else { break }
        var next = index + 1
        while next < data.endIndex, [9, 13, 32].contains(data[next]) { next += 1 }
        if next < data.endIndex, data[next] == 58 {
          key = value
        } else if let current = key {
          if depth == 1, current == "type" || current == "timestamp" { result[current] = value }
          if depth == 2, current == "role" { result[current] = value }
          key = nil
        }
      }
      index += 1
      if index < data.endIndex, data[index] == 44 { key = nil }
    }
    return result
  }
}
