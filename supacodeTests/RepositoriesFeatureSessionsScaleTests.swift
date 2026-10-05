import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// The real index holds thousands of sessions, and every agent status flip
/// runs these paths on the main thread.
@MainActor
struct RepositoriesFeatureSessionsScaleTests {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  private func fixture() -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    var sidecar: SessionSidecar = [:]
    var summaries: [SessionSummary] = []
    for index in 0..<2_800 {
      let age = Double(index) * 3_600
      let summary = SessionSummary(
        harness: .pi, sessionID: "s\(index)", createdAt: now.addingTimeInterval(-age - 60),
        cwd: "/fixture/dir\(index % 6)", title: "Session \(index)", messageCount: 10,
        lastActivity: now.addingTimeInterval(-age))
      summaries.append(summary)
      if index > 900 { sidecar[summary.id] = SessionSidecarEntry(settledAt: now, branches: ["main"]) }
    }
    state.$sessions = Shared(value: sidecar)
    state.$sidebar = Shared(value: SidebarState())
    state.$persistedLayouts = SharedReader(value: LayoutsFile(worktrees: [:]))
    state.sessionsStarted = true
    state.sessionsRestorationFinished = true
    state.sessionsRefreshSucceeded = true
    state.sessionSummaries = summaries
    state.sessionSnapshots = (0..<14).map { index in
      SessionLiveSnapshot(
        harness: .pi, sessionRef: "s\(index)", cwd: "/fixture/dir\(index % 6)",
        location: SessionLocation(
          worktreeID: "/fixture", tabID: TabID(), surfaceID: UUID()))
    }
    return state
  }

  private func milliseconds(_ work: () -> Void) -> Double {
    let start = ContinuousClock.now
    work()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
  }

  @Test(.dependencies) func statusFlipAndRefreshStayCheapAtRealIndexSize() {
    var state = fixture()
    state.reconcileSessionItems(now: now)
    state.recomputeSessionsSidebarStructureIfChanged()

    var recompute = 0.0
    let flip =
      milliseconds {
        for round in 0..<10 {
          state.sessionSnapshots[0].status = round.isMultiple(of: 2) ? .working : .idle
          state.reconcileSessionItems(now: now)
          recompute += milliseconds { state.recomputeSessionsSidebarStructureIfChanged() }
        }
      } / 10
    let settle =
      milliseconds {
        for _ in 0..<10 { state.autoSettleSessions(now: now, idleDays: 3) }
      } / 10
    // Debug-build budgets with headroom; the pre-fix status flip took ~700ms.
    #expect(state.sessionItems.count == 2_800)
    #expect(flip < 60, "status flip took \(flip)ms, recompute \(recompute / 10)ms")
    #expect(settle < 60, "auto-settle pass took \(settle)ms")
  }
}
