import SwiftUI

/// Wraps subviews onto multiple rows, like flowing text. Used for the variable
/// number of favorite workflow buttons on a project card.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
    let width = proposal.width ?? .infinity
    let rows = computeRows(maxWidth: width, subviews: subviews)
    let height = rows.reduce(into: 0) { partial, row in
      partial += row.height + (partial > 0 ? spacing : 0)
    }
    return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
    let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
    var originY = bounds.minY
    for row in rows {
      var originX = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: originX, y: originY), anchor: .topLeading, proposal: .unspecified)
        originX += size.width + spacing
      }
      originY += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let addedWidth = size.width + (current.indices.isEmpty ? 0 : spacing)
      if !current.indices.isEmpty, current.width + addedWidth > maxWidth {
        rows.append(current)
        current = Row()
      }
      current.indices.append(index)
      current.width += current.indices.count == 1 ? size.width : addedWidth
      current.height = max(current.height, size.height)
    }
    if !current.indices.isEmpty {
      rows.append(current)
    }
    return rows
  }
}
