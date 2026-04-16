import ComposableArchitecture
import Foundation

@Reducer
struct UpstreamUpdateFeature {
  @ObservableState
  struct State: Equatable {
    var status: UpstreamUpdateStatus?
    var isChecking = false
    var lastCheckedAt: Date?
  }

  enum Action {
    case checkForUpdates
    case checkCompleted(UpstreamUpdateStatus?)
    case dismiss
    case openInSupacode
  }

  private enum CancelID {
    static let check = "upstreamUpdate.check"
  }

  @Dependency(\.upstreamUpdateClient) private var upstreamUpdateClient
  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .checkForUpdates:
        guard !state.isChecking else { return .none }
        state.isChecking = true
        return .run { send in
          let repoPath = self.resolveSupacodeRepoPath()
          guard let repoPath else {
            await send(.checkCompleted(nil))
            return
          }
          let localBranch = self.currentBranch(repoPath: repoPath) ?? "HEAD"
          let result = await upstreamUpdateClient.checkForUpdates(repoPath, localBranch, "upstream")
          await send(.checkCompleted(result))
        }
        .cancellable(id: CancelID.check)

      case .checkCompleted(let result):
        state.isChecking = false
        state.lastCheckedAt = now
        state.status = result
        return .none

      case .dismiss:
        state.status = nil
        return .none

      case .openInSupacode:
        return .none
      }
    }
  }

  private func resolveSupacodeRepoPath() -> String? {
    let bundlePath = Bundle.main.bundlePath
    let url = URL(fileURLWithPath: bundlePath)
    var current = url.deletingLastPathComponent()
    for _ in 0..<10 {
      let gitPath = current.appendingPathComponent(".git").path
      if FileManager.default.fileExists(atPath: gitPath) {
        return current.path(percentEncoded: false)
      }
      let barePath = current.appendingPathComponent(".bare").path
      if FileManager.default.fileExists(atPath: barePath) {
        return current.path(percentEncoded: false)
      }
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
    return nil
  }

  private func currentBranch(repoPath: String) -> String? {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let process = Process()
    process.executableURL = env
    process.arguments = ["git", "-C", repoPath, "rev-parse", "--abbrev-ref", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return output?.isEmpty == false ? output : nil
    } catch {
      return nil
    }
  }
}
