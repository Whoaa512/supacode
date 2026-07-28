import ComposableArchitecture
import SwiftUI

/// Settings pane listing every active terminal surface across all worktrees,
/// with a text-based preview thumbnail, a jump-to button that focuses the
/// surface (closing settings), and a close button that kills it.
struct TerminalSessionsSettingsView: View {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager

  private let columns = [GridItem(.adaptive(minimum: 260), spacing: 12)]

  var body: some View {
    let overviews = terminalManager.sessionOverviews()
    ScrollView {
      if overviews.isEmpty {
        ContentUnavailableView(
          "No Terminal Sessions",
          systemImage: "terminal",
          description: Text("Surfaces appear here once a worktree has an open terminal.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
      } else {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(overviews) { worktree in
            VStack(alignment: .leading, spacing: 8) {
              Text(worktree.name)
                .font(.headline)
              LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(worktree.tabs) { tab in
                  ForEach(tab.surfaces) { surface in
                    TerminalSessionCardView(
                      store: store,
                      terminalManager: terminalManager,
                      worktreeID: worktree.id,
                      tabTitle: tab.title,
                      tabID: tab.id,
                      surface: surface
                    )
                  }
                }
              }
            }
          }
        }
        .padding(20)
      }
    }
    .navigationTitle("Terminal Sessions")
  }
}

/// One surface card: preview text (or an asleep placeholder for dormant
/// surfaces), the owning tab's title, and the focus / close actions.
private struct TerminalSessionCardView: View {
  let store: StoreOf<AppFeature>
  let terminalManager: WorktreeTerminalManager
  let worktreeID: Worktree.ID
  let tabTitle: String
  let tabID: TerminalTabID
  let surface: WorktreeTerminalManager.SessionSurfaceOverview

  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      preview
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        )
      HStack(spacing: 6) {
        Text(tabTitle)
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        Button {
          store.send(
            .focusTerminalSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surface.id))
          dismissWindow(id: WindowID.settings)
        } label: {
          Label("Focus Terminal", systemImage: "arrow.up.forward.square")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Focus this terminal and close Settings")
        Button(role: .destructive) {
          store.send(
            .closeTerminalSurface(worktreeID: worktreeID, tabID: tabID, surfaceID: surface.id))
        } label: {
          Label("Close Terminal", systemImage: "xmark.circle")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Close this terminal surface")
      }
    }
  }

  @ViewBuilder
  private var preview: some View {
    if surface.isDormant {
      VStack(spacing: 4) {
        Image(systemName: "moon.zzz")
          .font(.title3)
          .accessibilityHidden(true)
        Text("Asleep")
          .font(.caption)
      }
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.quaternary.opacity(0.5))
    } else {
      Text(previewText)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
        .background(.quaternary.opacity(0.5))
    }
  }

  /// Last visible lines of the surface's screen, trailing blanks trimmed.
  private var previewText: String {
    let contents = terminalManager.screenPreview(worktreeID: worktreeID, surfaceID: surface.id) ?? ""
    var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
      lines.removeLast()
    }
    return lines.suffix(9).joined(separator: "\n")
  }
}
