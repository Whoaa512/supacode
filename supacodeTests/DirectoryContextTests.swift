import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct DirectoryContextTests {
  @Test func localWorktreeFieldsMatch() {
    let worktree = Worktree(
      id: WorktreeID("/tmp/dir-context/wt"),
      name: "wt",
      detail: "",
      workingDirectory: URL(filePath: "/tmp/dir-context/wt", directoryHint: .notDirectory),
      repositoryRootURL: URL(filePath: "/tmp/dir-context/../dir-context", directoryHint: .notDirectory)
    )
    let context = DirectoryContext(worktree: worktree)
    #expect(context.worktreeID == worktree.id)
    #expect(context.name == "wt")
    #expect(context.workingDirectory == worktree.workingDirectory)
    #expect(context.repositoryRootURL == worktree.repositoryRootURL)
    #expect(context.host == nil)
    #expect(context.repositoryID == RepositoryID("/tmp/dir-context"))
    #expect(context.scriptEnvironment == worktree.scriptEnvironment)
  }

  @Test func remoteWorktreeFieldsMatch() {
    let host = RemoteHost(alias: "devbox")
    let worktree = Worktree(
      location: .remote(host, workingDirectory: "/home/me/proj/wt", repositoryRoot: "/home/me/proj"),
      kind: .git,
      name: "wt",
      detail: ""
    )
    let context = DirectoryContext(worktree: worktree)
    #expect(context.worktreeID == worktree.id)
    #expect(context.name == "wt")
    #expect(context.workingDirectory == worktree.workingDirectory)
    #expect(context.repositoryRootURL == worktree.repositoryRootURL)
    #expect(context.host == host)
    #expect(context.repositoryID == worktree.location.repositoryLocation.id)
  }
}
