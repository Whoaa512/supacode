import ComposableArchitecture
import SwiftUI

struct CommandPaletteBrowseView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  @FocusState private var isFilterFocused: Bool
  @State private var hoveredID: DirectoryEntry.ID?

  private var currentPathDisplay: String {
    store.browse.currentPath.path(percentEncoded: false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      browseHeader
      Divider()
      pathBar
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
      isFilterFocused = true
    }
  }

  private var browseHeader: some View {
    ZStack {
      hiddenKeyboardButtons

      TextField(
        "Filter directories...",
        text: Binding(
          get: { store.browse.filterQuery },
          set: { store.send(.browseFilterChanged($0)) },
        ),
      )
      .padding()
      .font(.title3.weight(.light))
      .frame(height: 48)
      .textFieldStyle(.plain)
      .focused($isFilterFocused)
      .onChange(of: isFilterFocused) { _, focused in
        if !focused {
          store.send(.setPresented(false))
        }
      }
      .onExitCommand { store.send(.setPresented(false)) }
      .onSubmit { store.send(.browseSubmit) }
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
      Button {
        store.send(.browseNavigateUp)
      } label: {
        Color.clear
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.leftArrow, modifiers: [.command])
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private var pathBar: some View {
    HStack(spacing: 4) {
      Button {
        store.send(.browseNavigateUp)
      } label: {
        Image(systemName: "chevron.left")
          .font(.caption.weight(.semibold))
          .accessibilityLabel("Navigate up")
      }
      .buttonStyle(.plain)
      .help("Navigate up")
      .disabled(store.browse.currentPath.path(percentEncoded: false) == "/")

      Text(currentPathDisplay)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)

      Spacer()

      if store.browse.isLoading {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
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

  private var browseFooter: some View {
    HStack {
      Button {
        store.send(.browseOpenNativePanel)
      } label: {
        Label("Open in Finder", systemImage: "folder")
          .font(.caption)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Fall back to native file picker")

      Spacer()

      Text("Enter to open · ⌘← to go up")
        .font(.caption2)
        .foregroundStyle(.quaternary)
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
    .help(entry.isGitRepo ? "Add \(entry.name) as repository" : "Open \(entry.name)")
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

extension NSColor {
  fileprivate var luminance: Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard let rgb = usingColorSpace(.sRGB) else { return 0 }
    rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return (0.299 * red) + (0.587 * green) + (0.114 * blue)
  }
}
