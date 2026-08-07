#if DEBUG
  import Foundation

  /// DEBUG-only tally of task-row body evaluations, so assertion A10 ("agent /
  /// terminal updates invalidate only the affected task leaf") can be *measured*
  /// rather than asserted by inspection.
  ///
  /// Manual verification (the SwiftUI half — body evaluation needs a real host,
  /// which a unit test doesn't have):
  ///
  /// 1. Run a DEBUG build with several tasks in the inbox and the Tasks tab open.
  /// 2. In the debugger: `expr TaskRowBodyEvalCounter.reset()`.
  /// 3. Drive activity on exactly one task (start an agent in its terminal, or
  ///    let a hook tick it).
  /// 4. `expr print(TaskRowBodyEvalCounter.snapshot())` — only the ticked task's
  ///    id may have a non-zero count.
  ///
  /// `@MainActor` because rows only ever render on the main actor; that also
  /// keeps the storage free of locks.
  @MainActor
  enum TaskRowBodyEvalCounter {
    private static var counts: [TaskID: Int] = [:]

    static func record(_ id: TaskID) {
      counts[id, default: 0] += 1
    }

    static func count(for id: TaskID) -> Int {
      counts[id] ?? 0
    }

    static func snapshot() -> [TaskID: Int] {
      counts
    }

    static func reset() {
      counts.removeAll()
    }
  }
#endif
