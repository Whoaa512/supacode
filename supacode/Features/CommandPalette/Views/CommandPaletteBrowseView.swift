import ComposableArchitecture
import SwiftUI

struct CommandPaletteBrowseView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  @FocusState private var isPathFocused: Bool
  @State private var hoveredID: DirectoryEntry.ID?
  @State private var hoveredKnownID: Worktree.ID?
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
  private static let newTaskPathHints = "↵ open · ⇥ complete · ⌘↵ start here · ⌘↑ up · ⇧⇥ agent/shell"
  private static let newTaskPathHintsHelp = """
    ↵ starts a task in a repository or enters a folder · ⇥ completes the path · \
    ⌘↵ starts a task in the folder itself · ⌘↑ goes up one level · ⇧⇥ toggles agent or shell
    """
  private static let newTaskKnownHints = "↵ start · ⇥ browse from here · ⇧⇥ agent/shell"
  private static let newTaskKnownHintsHelp = """
    ↵ starts a task in the highlighted directory · ⇥ browses the filesystem from it · \
    ⇧⇥ toggles agent or shell
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
          store.browse.purpose == .newSession ? "Directory, or ~/path" : "~/path/to/project",
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
      if store.browse.listsKnown {
        knownList
      } else if store.browse.filteredEntries.isEmpty && !store.browse.isLoading {
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

  private var knownList: some View {
    Group {
      if store.browse.knownMatches.isEmpty {
        VStack(spacing: 8) {
          Text("No matching directory. Type ~/ or / to browse.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(Array(store.browse.knownMatches.enumerated()), id: \.element.id) { index, directory in
                KnownDirectoryRow(
                  directory: directory,
                  isSelected: store.browse.selectedIndex == index,
                  isHovered: hoveredKnownID == directory.id,
                  onActivate: { store.send(.browseSelectKnown(directory.id)) },
                )
                .id(directory.id)
                .onHover { hovering in
                  hoveredKnownID = hovering ? directory.id : nil
                }
              }
            }
            .padding(10)
          }
          .frame(height: 200)
          .onChange(of: store.browse.selectedIndex) { _, newValue in
            guard let index = newValue,
              store.browse.knownMatches.indices.contains(index)
            else { return }
            proxy.scrollTo(store.browse.knownMatches[index].id)
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

      if store.browse.purpose == .newSession {
        Picker(
          "Start with",
          selection: Binding(
            get: { store.browse.kind },
            set: { store.send(.browseKindChanged($0)) },
          )
        ) {
          Text("Agent").tag(NewTaskKind.agent)
          Text("Shell").tag(NewTaskKind.shell)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Start the default agent (pi) or a plain shell (⇧⇥)")
      }

      Spacer()

      Text(keyboardHints)
        .font(.caption2)
        .foregroundStyle(.quaternary)
        .help(keyboardHintsHelp)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var keyboardHints: String {
    switch store.browse.purpose {
    case .openRepository: Self.keyboardHints
    case .newSession: store.browse.listsKnown ? Self.newTaskKnownHints : Self.newTaskPathHints
    }
  }

  private var keyboardHintsHelp: String {
    switch store.browse.purpose {
    case .openRepository: Self.keyboardHintsHelp
    case .newSession: store.browse.listsKnown ? Self.newTaskKnownHintsHelp : Self.newTaskPathHintsHelp
    }
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

private struct KnownDirectoryRow: View {
  let directory: NewTaskDirectory
  let isSelected: Bool
  let isHovered: Bool
  let onActivate: () -> Void

  var body: some View {
    Button(action: onActivate) {
      HStack(spacing: 8) {
        Image(systemName: directory.repositoryName == nil ? "folder" : "arrow.triangle.branch")
          .foregroundStyle(directory.repositoryName == nil ? .secondary : .primary)
          .font(.subheadline.weight(.medium))
          .frame(width: 16, height: 16, alignment: .center)
          .accessibilityHidden(true)

        Text(directory.name)
          .fontWeight(.medium)

        if let repositoryName = directory.repositoryName {
          Text(repositoryName)
            .foregroundStyle(.secondary)
        }

        Text(directory.path)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.head)

        Spacer()

        if let hostLabel = directory.hostLabel {
          Text(hostLabel)
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
    .help("Start a task in \(directory.name) (↵)")
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
