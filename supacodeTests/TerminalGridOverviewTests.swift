import Foundation
import SupacodeSettingsShared
import Testing

@testable import supacode

struct TerminalGridOverviewTests {
  @Test func activityBucketsPrioritizeAwaitingInputThenBusy() {
    #expect(TerminalGridOverview.Activity.resolve(agents: []) == .none)
    #expect(TerminalGridOverview.Activity.resolve(agents: [instance(.idle)]) == .idle)
    #expect(TerminalGridOverview.Activity.resolve(agents: [instance(.busy)]) == .busy)
    #expect(TerminalGridOverview.Activity.resolve(agents: [instance(.compacting)]) == .busy)
    #expect(TerminalGridOverview.Activity.resolve(agents: [instance(.awaitingInput)]) == .awaitingInput)
    #expect(TerminalGridOverview.Activity.resolve(agents: [instance(.error)]) == .awaitingInput)
    #expect(
      TerminalGridOverview.Activity.resolve(
        agents: [instance(.busy), instance(.error, agent: .codex)]) == .awaitingInput)
  }

  @Test func modelCachesCountsAndFilteredTiles() {
    let busy = makeTile(agents: [instance(.busy)])
    let idle = makeTile(agents: [instance(.idle)])
    let none = makeTile()
    let model = TerminalGridOverview.Model(
      tiles: [busy, idle, none],
      filter: .activity(.busy)
    )

    #expect(model.counts.total == 3)
    #expect(model.counts[.busy] == 1)
    #expect(model.counts[.idle] == 1)
    #expect(model.counts[.none] == 1)
    #expect(model.visibleTiles.map(\.id) == [busy.id])
  }

  @Test func clusteringGroupsRepositorySiblingsAndKeepsInputOrder() {
    let repoAFirst = makeTile(repositoryPath: "/repo/a", worktreeName: "a")
    let repoASecond = makeTile(repositoryPath: "/repo/a", worktreeName: "a")
    let repoB = makeTile(repositoryPath: "/repo/b", worktreeName: "b")

    let tiles = TerminalGridOverview.clustered([repoB, repoAFirst, repoASecond])

    #expect(tiles.map(\.id) == [repoAFirst.id, repoASecond.id, repoB.id])
  }

  @Test func tilesCarrySessionAndRepositoryFields() throws {
    let worktree = Worktree(
      id: "/repo/wt",
      name: "wt",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/repo/wt"),
      repositoryRootURL: URL(fileURLWithPath: "/repo")
    )
    let session = TerminalSession(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      directoryName: "wt",
      tabID: TabID(),
      tabTitle: "agent",
      surfaceID: UUID(),
      availability: .dormant,
      isFocused: true
    )

    let tile = try #require(
      TerminalGridOverview.tiles(
        sessions: [session],
        worktreeLookup: { $0 == worktree.id ? worktree : nil },
        agentsForSurface: { _ in [self.instance(.awaitingInput)] }
      ).first
    )

    #expect(tile.repositoryPath == "/repo")
    #expect(tile.availability == .dormant)
    #expect(tile.isFocused)
    #expect(tile.activity == .awaitingInput)
  }

  @Test func responsiveColumnCountUsesYouTubeStyleBreakpoints() {
    #expect(TerminalGridOverviewView.columnCount(width: 1500) == 3)
    #expect(TerminalGridOverviewView.columnCount(width: 2000) == 4)
    #expect(TerminalGridOverviewView.columnCount(width: 2500) == 5)
    #expect(TerminalGridOverviewView.columnCount(width: 700) == 2)
    #expect(TerminalGridOverviewView.columnCount(width: 400) == 1)
  }

  @Test func scrollbackPreviewStripsEscapesAndNormalizesLineEndings() {
    let raw = "\u{1b}[32mgreen\u{1b}[0m line\r\nnext\rprogress\u{1b}]0;title\u{07}done"
    #expect(ScrollbackPreview.strippedVisibleText(raw) == "green line\nnext\nprogressdone")
  }

  private func instance(
    _ activity: AgentPresenceFeature.Activity,
    agent: SkillAgent = .claude
  ) -> AgentPresenceFeature.AgentInstance {
    .init(agent: agent, activity: activity)
  }

  private func makeTile(
    repositoryPath: String = "/repo/a",
    worktreeName: String = "a",
    agents: [AgentPresenceFeature.AgentInstance] = []
  ) -> TerminalGridOverview.Tile {
    TerminalGridOverview.Tile(
      worktreeID: WorktreeID("\(repositoryPath)/\(worktreeName)"),
      worktreeName: worktreeName,
      directoryName: worktreeName,
      repositoryPath: repositoryPath,
      tabID: TabID(),
      tabTitle: "agent",
      surfaceID: UUID(),
      availability: .live,
      isFocused: false,
      agents: agents
    )
  }
}
