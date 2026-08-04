import ComposableArchitecture
import SwiftUI

struct CommandPaletteBrowseView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  @FocusState private var isPathFocused: Bool
  @State private var hoveredID: DirectoryEntry.ID?
  @State private var blurDismissTask: Task<Void, Never>?

  /// Focus can only be asserted once the field is mounted, and an outgoing query field can
  /// resign first responder a beat later, so the assertion is repeated after this delay.
  private static let focusReassertDelay = Duration.milliseconds(50)
  /// A blur has to persist this long before it dismisses the palette: switching into browse
  /// mode in place hands focus between two text fields, which reads as a momentary blur.
  private static let blurDismissDelay = Duration.milliseconds(150)

  private static let keyboardHints = "↵ open · ⇥ complete · ⌘↵ open folder · ⌘↑ up"
  private static let keyboardHintsHelp = """
    ↵ opens a repository or enters a folder · ⇥ completes the path · \
    ⌘↵ opens the folder itself · ⌘↑ goes up one level
    """

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      browseHeader
      Divider()
      browseList
      Divider()
      browseFooter
    }
    .frame(maxWidth: 500)
    .background(
      ZStack {
        Rectangle().fill(.ultraThinMaterial)
        Rectangle()
          .fill(Color(nsColor: .windowBackgroundColor))
          .blendMode(.color)
      }
      .compositingGroup()
    )
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
    )
    .shadow(radius: 32, x: 0, y: 12)
    .padding(16)
    .environment(\.colorScheme, windowColorScheme)
    .task {
      isPathFocused = true
      // The palette can enter browse mode while it is already open ("Open Repository"
      // picked from the command palette), where the outgoing query field resigns first
      // responder after this runs and drags focus off the freshly mounted path field.
      // Re-assert once; a no-op when the first assignment stuck.
      try? await Task.sleep(for: Self.focusReassertDelay)
      isPathFocused = true
    }
  }

  /// The path *is* the query: typing `~/code/sup` browses `~/code` and filters on `sup`,
  /// and any part of the path stays editable, so the user is never trapped in a directory.
  private var browseHeader: some View {
    ZStack {
      hiddenKeyboardButtons

      HStack(spacing: 8) {
        TextField(
          "~/path/to/project",
          text: Binding(
            get: { store.browse.pathQuery },
            set: { store.send(.browsePathQueryChanged($0)) },
          ),
        )
        .font(.title3.weight(.light).monospaced())
        .textFieldStyle(.plain)
        .focused($isPathFocused)
        .onChange(of: isPathFocused) { _, focused in
          blurDismissTask?.cancel()
          guard !focused else { return }
          // Debounced so a transient focus hand-off (or a momentary steal by the terminal
          // surface behind the panel) doesn't close the picker out from under the user.
          blurDismissTask = Task {
            try? await Task.sleep(for: Self.blurDismissDelay)
            guard !isPathFocused, store.isPresented else { return }
            store.send(.setPresented(false))
          }
        }
        .onExitCommand { store.send(.setPresented(false)) }
        .onSubmit { store.send(.browseSubmit) }

        if store.browse.isLoading {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding()
      .frame(height: 48)
    }
  }

  private var hiddenKeyboardButtons: some View {
    Group {
      Button {
        store.send(.browseMoveSelection(.upSelection))
      } label: {
        Color.clear
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.upArrow, modifiers: [])
      Button {
        store.send(.browseMoveSelection(.downSelection))
      } label: {
        Color.clear
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.downArrow, modifiers: [])
      Button {
        store.send(.browseMoveSelection(.upSelection))
      } label: {
        Color.clear
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.init("p"), modifiers: [.control])
      Button {
        store.send(.browseMoveSelection(.downSelection))
      } label: {
        Color.clear
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.init("n"), modifiers: [.control])
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private var browseList: some View {
    Group {
      if store.browse.filteredEntries.isEmpty && !store.browse.isLoading {
        VStack(spacing: 8) {
          Text("No directories found")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(store.browse.filteredEntries.enumerated()), id: \.element.id) { index, entry in
                BrowseEntryRow(
                  entry: entry,
                  relativeParent: Self.relativeParent(of: entry),
                  isSelected: store.browse.selectedIndex == index,
                  isHovered: hoveredID == entry.id,
                  onActivate: { store.send(.browseNavigate(entry)) },
                )
                .id(entry.id)
                .onHover { hovering in
                  hoveredID = hovering ? entry.id : nil
                }
              }
            }
            .padding(10)
          }
          .frame(height: 200)
          .onChange(of: store.browse.selectedIndex) { _, newValue in
            guard let index = newValue,
              store.browse.filteredEntries.indices.contains(index)
            else { return }
            proxy.scrollTo(store.browse.filteredEntries[index].id)
          }
        }
      }
    }
  }

  /// Nested search hits live below the browsed directory, so show where they came from.
  /// `nil` for direct children, whose name already says everything.
  private static func relativeParent(of entry: DirectoryEntry) -> String? {
    let parent = entry.relativePath.split(separator: "/").dropLast().joined(separator: "/")
    return parent.isEmpty ? nil : parent
  }

  private var browseFooter: some View {
    HStack {
      Button {
        store.send(.browseOpenNativePanel)
      } label: {
        Label("Choose Folder…", systemImage: "folder")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Fall back to the native macOS open panel to pick a folder")

      Spacer()

      Text(Self.keyboardHints)
        .font(.caption2)
        .foregroundStyle(.quaternary)
        .help(Self.keyboardHintsHelp)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var windowColorScheme: ColorScheme {
    NSColor.windowBackgroundColor.luminance > 0.5 ? .light : .dark
  }
}

private struct BrowseEntryRow: View {
  let entry: DirectoryEntry
  let relativeParent: String?
  let isSelected: Bool
  let isHovered: Bool
  let onActivate: () -> Void

  var body: some View {
    Button(action: onActivate) {
      HStack(spacing: 8) {
        Image(systemName: entry.isGitRepo ? "arrow.triangle.branch" : "folder")
          .foregroundStyle(entry.isGitRepo ? .primary : .secondary)
          .font(.subheadline.weight(.medium))
          .frame(width: 16, height: 16, alignment: .center)
          .accessibilityHidden(true)

        Text(entry.name)
          .fontWeight(entry.isGitRepo ? .medium : .regular)

        if let relativeParent {
          Text("in \(relativeParent)")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
        }

        Spacer()

        if entry.isGitRepo {
          Text("Repository")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(8)
      .contentShape(Rectangle())
      .background(rowBackground)
      .clipShape(.rect(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(entry.isGitRepo ? "Open \(entry.name) as a repository" : "Browse \(entry.name) (⌘↵ to open it)")
  }

  private var rowBackground: some View {
    Group {
      if isSelected {
        Color(nsColor: .selectedContentBackgroundColor)
      } else if isHovered {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      } else {
        Color.clear
      }
    }
  }
}
