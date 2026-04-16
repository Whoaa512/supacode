import ComposableArchitecture
import SwiftUI

struct UpstreamUpdateBannerView: View {
  let store: StoreOf<UpstreamUpdateFeature>

  var body: some View {
    if let status = store.status {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.circle.fill")
            .foregroundStyle(.blue)
            .font(.body)
            .accessibilityLabel("Upstream updates available")
          Text(
            "\(status.newCommitCount) new upstream \(status.newCommitCount == 1 ? "commit" : "commits")"
          )
          .font(.callout.weight(.medium))
          Spacer()
          Button {
            store.send(.dismiss)
          } label: {
            Image(systemName: "xmark")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .buttonStyle(.plain)
          .help("Dismiss")
        }

        if !status.commits.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(status.commits.prefix(5), id: \.hash) { commit in
              HStack(spacing: 4) {
                Text(String(commit.hash.prefix(7)))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(commit.subject)
                  .font(.caption)
                  .lineLimit(1)
              }
            }
            if status.commits.count > 5 {
              Text("… and \(status.commits.count - 5) more")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Button {
          store.send(.openInSupacode)
        } label: {
          Label("Open in Supacode", systemImage: "terminal")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open the Supacode project in Supacode to work on updates")
      }
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
  }
}
