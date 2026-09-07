import SwiftUI

/// Temporary root view so the app target has something to show before the
/// Evoto-style editor shell exists. Replaced in Phase 1 item 4.
public struct PlaceholderRootView: View {
    private let modules: [String]

    public init(modules: [String]) {
        self.modules = modules
    }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Retouch Pro")
                .font(.largeTitle.weight(.semibold))
            Text("Skeleton build — editor UI arrives in Phase 1 item 4.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(modules, id: \.self) { module in
                    Text(module)
                        .font(.system(.caption, design: .monospaced))
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    PlaceholderRootView(modules: ["RPCore 0.1.0", "RPUI 0.1.0"])
}
