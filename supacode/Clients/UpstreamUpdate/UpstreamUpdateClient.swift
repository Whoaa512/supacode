import ComposableArchitecture
import Foundation

struct UpstreamCommit: Equatable, Sendable {
  let hash: String
  let subject: String
  let date: String
}

struct UpstreamUpdateStatus: Equatable, Sendable {
  let newCommitCount: Int
  let commits: [UpstreamCommit]
  let repositoryPath: String
}

struct UpstreamUpdateClient {
  var checkForUpdates:
    @Sendable (_ repoPath: String, _ localBranch: String, _ remoteName: String) async
      -> UpstreamUpdateStatus?
}

extension UpstreamUpdateClient: DependencyKey {
  static let liveValue = UpstreamUpdateClient(
    checkForUpdates: { repoPath, localBranch, remoteName in
      let env = URL(fileURLWithPath: "/usr/bin/env")
      let gitDir = repoPath

      let fetchResult = try? ShellProcess.run(
        env,
        ["git", "-C", gitDir, "fetch", remoteName, "--quiet"],
      )
      guard fetchResult != nil else { return nil }

      let remoteBranch = "\(remoteName)/main"
      let rangeArg = "\(localBranch)..\(remoteBranch)"
      guard
        let countOutput = try? ShellProcess.run(
          env,
          ["git", "-C", gitDir, "rev-list", "--count", rangeArg],
        )
      else { return nil }

      let countString = countOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let count = Int(countString), count > 0 else { return nil }

      let logFormat = "%H|||%s|||%ad"
      let logResult = try? ShellProcess.run(
        env,
        [
          "git", "-C", gitDir, "log", "--format=\(logFormat)", "--date=relative",
          "\(rangeArg)", "--max-count=20",
        ],
      )

      var commits: [UpstreamCommit] = []
      if let logOutput = logResult?.stdout {
        for line in logOutput.split(separator: "\n") {
          let parts = line.split(separator: "|||", maxSplits: 2)
          guard parts.count == 3 else { continue }
          commits.append(
            UpstreamCommit(
              hash: String(parts[0]),
              subject: String(parts[1]),
              date: String(parts[2]),
            )
          )
        }
      }

      return UpstreamUpdateStatus(
        newCommitCount: count,
        commits: commits,
        repositoryPath: repoPath,
      )
    }
  )

  static let testValue = UpstreamUpdateClient(
    checkForUpdates: { _, _, _ in nil }
  )
}

extension DependencyValues {
  var upstreamUpdateClient: UpstreamUpdateClient {
    get { self[UpstreamUpdateClient.self] }
    set { self[UpstreamUpdateClient.self] = newValue }
  }
}

private enum ShellProcess {
  struct Output {
    let stdout: String
    let stderr: String
  }

  static func run(
    _ executable: URL,
    _ arguments: [String],
  ) throws -> Output {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return Output(
      stdout: String(data: stdoutData, encoding: .utf8) ?? "",
      stderr: String(data: stderrData, encoding: .utf8) ?? "",
    )
  }
}
