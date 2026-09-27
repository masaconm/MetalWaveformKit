//
//  HardwareButtonStyle.swift
//  RenderingDemo
//
//  責務: 再生・キュー操作で共用する、角丸の筐体と押下時の陰影
//

import SwiftUI

/// 操作や選択状態は呼び出し元が管理し、このスタイルは色と立体感だけを受け持つ。
struct HardwareButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var foregroundColor: Color
    // 点灯は再生中などの継続状態を表す。タッチ中の状態は configuration.isPressed から読む。
    var illuminated = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        configuration.label
            .foregroundStyle(foregroundColor)
            .shadow(color: foregroundColor.opacity(illuminated ? 0.55 : 0.15),
                    radius: illuminated ? 4 : 1)
            .background {
                shape.fill(LinearGradient(
                    colors: [Color(white: configuration.isPressed ? 0.10 : 0.21), Color(white: 0.07)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
            .overlay {
                shape.strokeBorder(.black.opacity(0.85), lineWidth: 2)
                shape.inset(by: 3).strokeBorder(LinearGradient(
                    colors: [.white.opacity(configuration.isPressed ? 0.08 : 0.24), .white.opacity(0.03)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.15 : 0.4),
                    radius: 2, y: configuration.isPressed ? 0 : 2)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
    }
}
