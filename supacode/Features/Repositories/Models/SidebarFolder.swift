import Foundation
import IdentifiedCollections

struct SidebarFolder: Identifiable, Equatable, Codable, Hashable, Sendable {
  let id: UUID
  var name: String
  var repositoryIDs: [Repository.ID]

  init(id: UUID = UUID(), name: String, repositoryIDs: [Repository.ID] = []) {
    self.id = id
    self.name = name
    self.repositoryIDs = repositoryIDs
  }
}

enum SidebarRootItemID: Equatable, Hashable, Codable, Sendable {
  case folder(UUID)
  case repository(Repository.ID)
}
