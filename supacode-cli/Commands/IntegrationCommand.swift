import ArgumentParser
import Darwin
import Foundation

struct IntegrationCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "integration",
    abstract: "Forward coding-agent integration events to Supacode.",
    shouldDisplay: false,
    subcommands: [EventCommand.self]
  )
}

extension IntegrationCommand {
  struct EventCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "event",
      abstract: "Forward a structured coding-agent hook event.",
      shouldDisplay: false
    )

    @Argument(help: "Agent name.")
    var agent: String

    @Argument(help: "Event name.")
    var event: String

    mutating func run() throws {
      let environment = ProcessInfo.processInfo.environment
      guard let socketPath = environment["SUPACODE_SOCKET_PATH"],
        let surfaceID = environment["SUPACODE_SURFACE_ID"],
        UUID(uuidString: surfaceID) != nil
      else { return }

      let input = FileHandle.standardInput.readDataToEndOfFile()
      guard let data = try? JSONSerialization.jsonObject(with: input),
        JSONSerialization.isValidJSONObject(data)
      else { return }

      let hookEvent: [String: Any] = [
        "v": 1,
        "agent": agent,
        "event": event,
        "surface_id": surfaceID,
        "pid": getppid(),
        "data": data,
      ]
      let envelope = try JSONSerialization.data(withJSONObject: ["hook_event": hookEvent])
      _ = try SocketClient.sendAndReceive(
        to: socketPath,
        data: envelope,
        readTimeoutSeconds: 2
      )
    }
  }
}
