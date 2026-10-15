import SwiftUI

/// Keep native controls at their intrinsic width; stack actions when translated
/// labels no longer fit. State and asynchronous operations belong to the caller.
struct AdaptiveActionRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
                .fixedSize()
            VStack(alignment: .leading, spacing: 8) { content }
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
