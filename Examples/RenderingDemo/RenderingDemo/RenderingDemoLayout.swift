//
//  RenderingDemoLayout.swift
//  RenderingDemo
//
//  責務: 操作・説明の実測サイズから、波形へ割り当てる高さと各領域の位置を決める
//

import SwiftUI

/// 宣言順を一列配置の並び順として使う。二列配置では解説だけを右側へ移す。
enum RenderingDemoSection: CaseIterable {
    case header, waveform, transport, cues, scenarios
}

struct RenderingDemoSectionKey: LayoutValueKey {
    static let defaultValue = RenderingDemoSection.header
}

/// Viewの計測と配置を同じパスで行い、回転やマーカー操作による後追いの高さ補正を避ける。
struct RenderingDemoLayout: Layout {
    enum Arrangement: Equatable {
        case fittedColumn
        case scrollingColumn
        case twoColumns
    }

    var viewportSize: CGSize
    var arrangement: Arrangement
    var spacing: CGFloat
    var columnSpacing: CGFloat = 16
    /// 一列配置で波形に割り当てる高さの範囲。下限は統計表示と操作のための確保分。
    var waveformHeightRange: ClosedRange<CGFloat> = 100...280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        metrics(for: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = metrics(for: subviews)
        for subview in subviews {
            guard let frame = metrics.frames[subview[RenderingDemoSectionKey.self]] else { continue }
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct Metrics {
        var size: CGSize
        var frames: [RenderingDemoSection: CGRect]
    }

    /// 計測と配置で共通の寸法を求める。利用可能な高さから操作部を引き、残りを波形へ渡す。
    private func metrics(for subviews: Subviews) -> Metrics {
        let width = max(0, viewportSize.width)
        let availableHeight = max(0, viewportSize.height)
        let isTwoColumns = arrangement == .twoColumns
        let columnWidth = isTwoColumns ? max(0, (width - columnSpacing) / 2) : width
        let naturalProposal = ProposedViewSize(width: columnWidth, height: nil)

        // 波形以外は実際の文字・言語・文字サイズで計測する。機種ごとの定数は持たない。
        // 配置される領域だけを数え、余白を過不足なく扱う。
        let presentSections = Set(subviews.map { $0[RenderingDemoSectionKey.self] })
        let columnSections = RenderingDemoSection.allCases.filter { section in
            presentSections.contains(section) && !(isTwoColumns && section == .scenarios)
        }
        let columnGaps = CGFloat(max(0, columnSections.count - 1))
        var heights: [RenderingDemoSection: CGFloat] = [:]
        for subview in subviews where subview[RenderingDemoSectionKey.self] != .waveform {
            heights[subview[RenderingDemoSectionKey.self]] = subview.sizeThatFits(naturalProposal).height
        }
        let controlsHeight = (heights[.header] ?? 0) + (heights[.transport] ?? 0) + (heights[.cues] ?? 0)
        let naturalScenarioHeight = heights[.scenarios] ?? 0

        switch arrangement {
        case .fittedColumn:
            // 指定された下限（既定100pt）を波形に確保し、通常は説明も含めて画面内に収める。
            // 狭い画面で説明が収まらない場合は、説明パネル内だけをスクロールさせる。
            let remaining = availableHeight - controlsHeight - spacing * columnGaps
            heights[.waveform] = min(max(remaining - naturalScenarioHeight, waveformHeightRange.lowerBound),
                                     waveformHeightRange.upperBound)
            if presentSections.contains(.scenarios) {
                heights[.scenarios] = min(naturalScenarioHeight, max(0, remaining - (heights[.waveform] ?? 0)))
            }
        case .twoColumns:
            heights[.waveform] = max(100, min(240, availableHeight - controlsHeight - spacing * columnGaps))
            heights[.scenarios] = availableHeight
        case .scrollingColumn:
            // iPadや大きな文字では波形の高さを保ち、画面全体の縦スクロールを使う。
            heights[.waveform] = 280
        }

        var frames: [RenderingDemoSection: CGRect] = [:]
        var nextY: CGFloat = 0
        for section in RenderingDemoSection.allCases where presentSections.contains(section) {
            let height = heights[section] ?? 0
            if isTwoColumns && section == .scenarios {
                frames[section] = CGRect(x: columnWidth + columnSpacing, y: 0, width: columnWidth, height: height)
            } else {
                frames[section] = CGRect(x: 0, y: nextY, width: columnWidth, height: height)
                nextY += height + spacing
            }
        }
        return Metrics(
            size: CGSize(width: width, height: max(availableHeight, nextY - spacing)),
            frames: frames
        )
    }
}
