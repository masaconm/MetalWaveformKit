//
//  ExplanationLanguage.swift
//  RenderingDemo
//
//  責務: 解説文だけの言語選択と、共通の切り替えメニュー
//

import Foundation
import SwiftUI

/// 解説文だけの言語を選ぶ。タイトル、ボタン名、数値の書式は画面側の指定を保つ。
enum ExplanationLanguage: String, CaseIterable {
    case english = "en"
    case japanese = "ja"

    /// 初回はシステムの優先言語に合わせ、日本語以外は英語を使う。以後の選択は画面側で保存する。
    static var preferred: Self {
        let identifier = Locale.preferredLanguages.first ?? "en"
        return Locale(identifier: identifier).language.languageCode?.identifier == "ja" ? .japanese : .english
    }

    var title: String { self == .japanese ? "日本語" : "English" }
    var code: String { self == .japanese ? "JA" : "EN" }

    func text(_ english: String) -> String {
        // 画面全体のlocaleを変えず、選択された解説用テーブルだけを参照する。
        // 翻訳やリソースが見つからない場合も、内部キーではなく元の英文を表示する。
        let languages = self == .english ? ["en"] : [rawValue, "en"]
        for language in languages {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let localized = bundle.localizedString(forKey: english, value: english, table: "Explanations")
            if localized != english || language == "en" { return localized }
        }
        return english
    }
}

/// 通常画面と比較画面で同じ選択値を共有するメニュー。
struct ExplanationLanguageMenu: View {
    @Binding var language: ExplanationLanguage

    var body: some View {
        Menu {
            ForEach(ExplanationLanguage.allCases, id: \.self) { option in
                Button { language = option } label: {
                    if language == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(verbatim: option.title)
                    }
                }
                .accessibilityIdentifier("explanations-\(option.rawValue)")
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "globe")
                    .font(.system(size: 16, weight: .medium))
                Text(verbatim: language.code)
                    .font(.caption2.weight(.semibold))
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(HardwareButtonStyle(foregroundColor: .white.opacity(0.85)))
        .accessibilityLabel("Descriptions")
        .accessibilityValue(language.title)
        .accessibilityIdentifier("explanations-language")
        .help("Descriptions")
    }
}
