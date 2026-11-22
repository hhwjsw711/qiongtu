import SwiftUI

/// 历史图库里一张图的处理步骤：从原图开始一步一步做了什么。可以套到一张新照片上。
struct RecipeSheet: View {
    let recipe: EditRecipe
    var onApply: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("处理步骤")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 18)
                .padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { i, step in
                        row(i + 1, step)
                        if i < recipe.steps.count - 1 {
                            Divider().background(Color.white.opacity(0.08)).padding(.leading, 64)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button(action: onApply) {
                Text("套用到新照片")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .disabled(recipe.copyable == 0)
            .opacity(recipe.copyable == 0 ? 0.4 : 1)
            .padding(16)
        }
        .foregroundStyle(.white)
        .background(Theme.panel.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func row(_ n: Int, _ step: RecipeStep) -> some View {
        let skipped = step.action == nil
        let isAI: Bool = {
            if case .ai? = step.action { return true }
            return false
        }()
        return HStack(spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.dim)
                .frame(width: 18)
            Image(systemName: step.symbol)
                .font(.system(size: 16))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.title).font(.system(size: 15, weight: .medium))
                    if isAI {
                        Text("AI")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if skipped {
                Text("跳过")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 11)
        .opacity(skipped ? 0.45 : 1)
    }
}
