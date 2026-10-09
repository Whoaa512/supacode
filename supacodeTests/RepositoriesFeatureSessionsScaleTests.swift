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

  private func fixture(rows: Int = 2_800) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    var sidecar: SessionSidecar = [:]
    var summaries: [SessionSummary] = []
    for index in 0..<rows {
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
    state.$persistedLayouts = SharedReader(value: TaskLayoutsFile())
    state.sessionsStarted = true
    state.sessionsRestorationFinished = true
    state.sessionsRefreshSucceeded = true
    state.sessionSummaries = summaries
    state.sessionSnapshots = (0..<14).map { index in
      SessionLiveSnapshot(
        harness: .pi, sessionRef: "s\(index)", cwd: "/fixture/dir\(index % 6)",
        location: SessionLocation(
          layoutID: "/fixture", directoryID: "/fixture", tabID: TabID(), surfaceID: UUID()))
    }
    return state
  }

  private func reconciled(rows: Int) -> RepositoriesFeature.State {
    var state = fixture(rows: rows)
    state.reconcileSessionItems(now: now)
    return state
  }

  /// Fires `onChange` on the first write to the row collection, the selection
  /// or any field of any row.
  private func observeRows(of state: RepositoriesFeature.State, onChange: @escaping @Sendable () -> Void) {
    withObservationTracking {
      _ = state.sessionItems.count
      _ = state.sessionSelection
      for row in state.sessionItems {
        _ = (row.title, row.cwd, row.createdAt, row.lifecycle, row.location)
        _ = (row.status, row.allowsAttentionNavigation, row.branchAnnotation, row.isSynthetic)
      }
    } onChange: {
      onChange()
    }
  }

  private func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
  }

  private func unchangedReconcileMedian(rows: Int) -> Double {
    var state = reconciled(rows: rows)
    return median(
      (0..<5).map { _ in
        milliseconds {
          for _ in 0..<3 { state.reconcileSessionItems(now: now) }
        } / 3
      })
  }

  /// A26: a status flip reconciles the whole index, so a pass over unchanged
  /// input must not touch a single row.
  @Test(.dependencies) func unchangedReconcileWritesNothing() {
    var state = reconciled(rows: 3_000)
    #expect(state.sessionItems.count == 3_000)
    let before = state
    let wrote = LockIsolated(false)
    observeRows(of: state) { wrote.setValue(true) }

    state.reconcileSessionItems(now: now)

    #expect(!wrote.value)
    #expect(state == before)

    // The same observation does fire for a real change, so the check above is not vacuous.
    state.sessionSnapshots[0].status = .working
    state.reconcileSessionItems(now: now)
    #expect(wrote.value)
  }

  /// A26: reconcile stays linear in the number of rows.
  @Test(.dependencies) func unchangedReconcileScalesLinearly() {
    let small = unchangedReconcileMedian(rows: 3_000)
    let large = unchangedReconcileMedian(rows: 6_000)
    #expect(large <= small * 3, "3,000 rows: \(small)ms, 6,000 rows: \(large)ms")
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
