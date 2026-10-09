import Darwin
import Dependencies

/// Whether one local process was started, directly or not, by another.
nonisolated struct ProcessAncestryClient: Sendable {
  var isDescendant: @Sendable (_ pid: pid_t, _ ancestor: pid_t) -> Bool
}

extension ProcessAncestryClient: DependencyKey {
  static let liveValue = ProcessAncestryClient { pid, ancestor in
    var current = pid
    // Bounded: a process tree is shallow, and a pid recycled mid-walk must not loop.
    for _ in 0..<64 {
      guard let parent = parentPID(of: current), parent > 1 else { return false }
      if parent == ancestor { return true }
      current = parent
    }
    return false
  }

  static let testValue = ProcessAncestryClient { _, _ in false }

  private static func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }
}

extension DependencyValues {
  var processAncestry: ProcessAncestryClient {
    get { self[ProcessAncestryClient.self] }
    set { self[ProcessAncestryClient.self] = newValue }
  }
}
