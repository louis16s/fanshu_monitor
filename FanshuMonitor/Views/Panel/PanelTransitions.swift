import SwiftUI

extension AnyTransition {
    static var panelDetailDisclosure: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity
        )
    }
}
