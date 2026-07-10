import ComposableArchitecture
import SwiftUI

/// One compact card per the v1 spec: question + recommendation, a kind badge,
/// evidence/context refs, source session + relative time, and the three
/// actions. System colors only, Dynamic Type throughout.
struct DecisionInboxCard: View {
  let candidate: AttentionCandidate
  let store: StoreOf<DecisionInboxFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        KindBadge(kind: candidate.kind)
        Spacer()
        Text(candidate.occurredAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(candidate.question ?? candidate.kind.headline)
        .font(.callout.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)

      if let recommendation = candidate.recommendation, !recommendation.isEmpty {
        Label(recommendation, systemImage: "sparkles")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !candidate.contextRefs.isEmpty {
        Label(candidate.contextRefs.joined(separator: ", "), systemImage: "doc.text")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Text("session \(candidate.sessionID.uuidString.prefix(8))")
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)

      HStack(spacing: 8) {
        Button("Focus Terminal") { store.send(.focusTapped(id: candidate.id)) }
          .help("Jump to the terminal surface that raised this")
        Button("Copy Response") { store.send(.copyTapped(id: candidate.id)) }
          .help("Copy the suggested response to the clipboard")
        Spacer()
        Button {
          store.send(.dismissTapped(id: candidate.id))
        } label: {
          Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
        }
        .help("Dismiss without acting")
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .padding(.top, 2)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
  }
}

private struct KindBadge: View {
  let kind: AttentionCandidate.Kind

  var body: some View {
    Text(kind.headline)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(kind.tint.opacity(0.2)))
      .foregroundStyle(kind.tint)
  }
}

extension AttentionCandidate.Kind {
  /// Short human label for the badge and the card headline fallback.
  var headline: String {
    switch self {
    case .inputRequested: "Decision"
    case .awaitingInput: "Awaiting input"
    case .notification: "Notification"
    case .processExited(let failure): failure ? "Process failed" : "Process exited"
    }
  }

  /// System-color tint by severity; no custom colors.
  var tint: Color {
    switch self {
    case .inputRequested: .accentColor
    case .awaitingInput: .orange
    case .notification: .secondary
    case .processExited(let failure): failure ? .red : .secondary
    }
  }
}
