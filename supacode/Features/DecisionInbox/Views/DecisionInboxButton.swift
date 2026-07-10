import ComposableArchitecture
import SwiftUI

/// Unobtrusive entry point for the decision inbox: a toolbar-style button with a
/// count badge that opens the inbox in a popover. Placed in the sidebar bottom
/// inset alongside the existing bottom card — the clearest precedent in the app
/// for a persistent, low-chrome control — rather than inventing a toolbar the
/// window doesn't otherwise have.
struct DecisionInboxButton: View {
  @Bindable var store: StoreOf<DecisionInboxFeature>

  var body: some View {
    Button {
      store.isPresented.toggle()
    } label: {
      Label {
        Text("Inbox")
      } icon: {
        Image(systemName: store.unresolvedCount > 0 ? "tray.full" : "tray")
      }
      .labelStyle(.iconOnly)
      .overlay(alignment: .topTrailing) {
        if store.unresolvedCount > 0 {
          Text(store.unresolvedCount > 99 ? "99+" : "\(store.unresolvedCount)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
            .offset(x: 8, y: -8)
        }
      }
    }
    .buttonStyle(.borderless)
    .help(
      store.unresolvedCount > 0
        ? "\(store.unresolvedCount) decision(s) waiting — open inbox"
        : "Decision inbox (no items waiting)")
    .popover(isPresented: $store.isPresented, arrowEdge: .top) {
      DecisionInboxPanel(store: store)
    }
  }
}

/// The popover body: the list of candidate cards, or an empty state.
private struct DecisionInboxPanel: View {
  @Bindable var store: StoreOf<DecisionInboxFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Decision Inbox")
        .font(.headline)
        .padding(12)
      Divider()
      if store.candidates.isEmpty {
        Text("Nothing needs your attention.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(store.candidates) { candidate in
              DecisionInboxCard(candidate: candidate, store: store)
            }
          }
          .padding(12)
        }
        .frame(maxHeight: 420)
      }
    }
    .frame(width: 340)
  }
}
