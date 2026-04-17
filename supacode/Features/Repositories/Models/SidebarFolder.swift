import Foundation

struct SidebarFolder: Identifiable, Equatable, Codable, Hashable {
  let id: UUID
  var name: String
  var repositoryIDs: [Repository.ID]

  init(id: UUID = UUID(), name: String, repositoryIDs: [Repository.ID] = []) {
    self.id = id
    self.name = name
    self.repositoryIDs = repositoryIDs
  }
}

enum SidebarRootItemID: Equatable, Hashable, Codable {
  case folder(UUID)
  case repository(Repository.ID)
}
