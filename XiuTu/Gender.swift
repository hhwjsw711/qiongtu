import SwiftUI

/// 美颜、美体、美发、妆容用"女"还是"男"的那一套。全 App 共用一个开关，记住上次选的。
@Observable
final class GenderSetting {
    static let shared = GenderSetting()

    var isMale: Bool {
        didSet { UserDefaults.standard.set(isMale, forKey: "gender.male") }
    }

    private init() {
        isMale = UserDefaults.standard.bool(forKey: "gender.male")
    }
}

/// 面板上的"女 / 男"切换。
struct GenderToggle: View {
    private let setting = GenderSetting.shared

    var body: some View {
        HStack(spacing: 0) {
            item("女", on: !setting.isMale) { setting.isMale = false }
            item("男", on: setting.isMale) { setting.isMale = true }
        }
        .padding(2)
        .background(Theme.chip, in: Capsule())
    }

    private func item(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: on ? .bold : .regular))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 34, height: 26)
                .background(on ? Theme.accent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
