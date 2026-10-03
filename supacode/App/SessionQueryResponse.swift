import Foundation
import IdentifiedCollections

enum SessionQueryResponse {
  enum Key {
    static let id = "id"
    static let title = "title"
    static let cwd = "cwd"
    static let lifecycle = "lifecycle"
    static let live = "live"
    static let status = "status"
    static let branch = "branch"
    static let surfaceID = "surfaceID"
    static let all = [id, title, cwd, lifecycle, live, status, branch, surfaceID]
  }

  static func rows(repositories: RepositoriesFeature.State) -> [[String: String]] {
    repositories.sessionsSidebarStructure.allIDs.compactMap { id in
      guard case .session(let key) = id,
        let item = repositories.sessionItems[id: id]
      else { return nil }
      return [
        Key.id: key.rawValue,
        Key.title: item.title,
        Key.cwd: item.cwd,
        Key.lifecycle: item.lifecycle == .active ? "active" : "settled",
        Key.live: item.isLive ? "1" : "",
        Key.status: item.status?.rawValue ?? "",
        Key.branch: item.branchAnnotation ?? repositories.sessions[key]?.branches.last ?? "",
        Key.surfaceID: item.location?.surfaceID.uuidString ?? "",
      ]
    }
  }
}
