import Foundation
import Testing

@testable import supacode

/// Title cascade (plan Resolved #15). The seeder's day-one bulk seeding is
/// gone — tasks are born only through ⌘N and promote — but both paths still
/// title records through `TaskActivitySeeder.title(for:branch:)`.
struct TaskActivitySeederTests {
  @Test func titlePrefersCustomizationTitle() {
    let title = TaskActivitySeeder.title(
      for: .init(
        directoryPath: "/repos/app",
        customizationTitle: "Inbox rewrite",
        worktreeName: "app",
        worktreeDetail: "detail"
      ),
      branch: "main"
    )
    #expect(title == "Inbox rewrite")
  }

  @Test func titleFallsBackThroughNameDetailBranchThenLeaf() {
    let base = TaskActivitySeeder.Candidate(directoryPath: "/repos/app-1/")

    var withName = base
    withName.worktreeName = "worktree-name"
    withName.worktreeDetail = "worktree-detail"
    #expect(TaskActivitySeeder.title(for: withName, branch: "main") == "worktree-name")

    var withDetail = base
    withDetail.worktreeName = "  "
    withDetail.worktreeDetail = "worktree-detail"
    #expect(TaskActivitySeeder.title(for: withDetail, branch: "main") == "worktree-detail")

    #expect(TaskActivitySeeder.title(for: base, branch: "main") == "main")

    #expect(TaskActivitySeeder.title(for: base, branch: nil) == "app-1")
  }

  @Test func blankFieldsAreTreatedAsAbsent() {
    let title = TaskActivitySeeder.title(
      for: .init(
        directoryPath: "/repos/app",
        customizationTitle: "   ",
        worktreeName: "",
        worktreeDetail: " "
      ),
      branch: "  "
    )
    #expect(title == "app")
  }

  @Test func duplicateTitlesAreAllowed() {
    let titles = (1...3).map { index in
      TaskActivitySeeder.title(
        for: .init(directoryPath: "/repos/pool-\(index)"),
        branch: "main"
      )
    }
    #expect(titles == ["main", "main", "main"])
  }
}
