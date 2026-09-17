import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

struct TerminalSessionsSettingsView: View {
  let store: StoreOf<AppFeature>
  @Dependency(TerminalClient.self) private var terminalClient

  private let columns = [GridItem(.adaptive(minimum: 280), spacing: 12)]

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      let sessions = terminalClient.listSurfaces()
      ScrollView {
        if sessions.isEmpty {
          ContentUnavailableView(
            "No Terminal Sessions",
            systemImage: "terminal",
            description: Text("Open a terminal in a worktree and it will appear here.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
        } else {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(sessions) { session in
              TerminalSessionCardView(store: store, session: session)
            }
          }
          .padding(20)
        }
      }
    }
    .navigationTitle("Terminal Sessions")
  }
}

private struct TerminalSessionCardView: View {
  let store: StoreOf<AppFeature>
  let session: TerminalSession
  @Dependency(TerminalClient.self) private var terminalClient
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      preview
      HStack(spacing: 6) {
        VStack(alignment: .leading, spacing: 2) {
          Text(session.worktreeName)
            .appFont(.headline)
            .lineLimit(1)
          Text(session.tabTitle)
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        Button {
          store.send(
            .focusTerminalSurface(
              worktreeID: session.worktreeID,
              tabID: session.tabID,
              surfaceID: session.surfaceID
            )
          )
          dismissWindow(id: WindowID.settings)
        } label: {
          Label("Focus Terminal", systemImage: "arrow.up.forward.square")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Focus this terminal and close Settings")
        Button(role: .destructive) {
          store.send(
            .closeTerminalSurface(
              worktreeID: session.worktreeID,
              tabID: session.tabID,
              surfaceID: session.surfaceID
            )
          )
        } label: {
          Label("Close Terminal", systemImage: "xmark.circle")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Close this terminal through the normal teardown path")
      }
      HStack(spacing: 6) {
        Label(statusLabel, systemImage: statusImage)
        if session.isFocused {
          Label("Focused", systemImage: "scope")
        }
        Spacer(minLength: 0)
        Text(session.surfaceID.uuidString.prefix(8))
          .appFont(.caption2, monospaced: true)
          .foregroundStyle(.tertiary)
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
  }

  private var preview: some View {
    Group {
      if let previewText {
        Text(previewText)
          .appFont(.caption2, monospaced: true)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .padding(8)
      } else {
        ContentUnavailableView(
          session.availability == .live ? "No Output" : "No Saved Preview",
          systemImage: session.availability == .live ? "terminal" : "moon.zzz"
        )
      }
    }
    .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 130)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
  }

  private var previewText: String? {
    guard let contents = terminalClient.sessionPreview(session.worktreeID, session.surfaceID) else {
      return nil
    }
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    guard !lines.isEmpty else { return nil }
    return lines.suffix(12).joined(separator: "\n")
  }

  private var statusLabel: String {
    switch session.availability {
    case .live: "Live"
    case .dormant: "Dormant"
    case .snapshot: "Saved snapshot"
    }
  }

  private var statusImage: String {
    switch session.availability {
    case .live: "circle.fill"
    case .dormant: "moon.zzz"
    case .snapshot: "externaldrive"
    }
  }
}
