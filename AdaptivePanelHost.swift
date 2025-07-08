import SwiftUI
import UIKit

/// A SwiftUI `UIViewControllerRepresentable` that hosts a `FloatingPanelController`.
/// This struct bridges the gap between SwiftUI's declarative UI and UIKit's imperative `UIViewController`
/// for managing a dynamic, draggable panel.
struct AdaptivePanelUIKitHost<Content: View>: UIViewControllerRepresentable {
    /// A binding to a boolean indicating if the panel is at its default (collapsed) snap point.
    @Binding var isAtDefault: Bool
    /// A binding to a CGFloat representing the panel's expansion progress (0.0 to 1.0).
    @Binding var expansionProgress: CGFloat
    /// A binding to a boolean indicating if the panel is currently being dragged horizontally.
    @Binding var isDraggingHorizontally: Bool
    /// A binding to a `PanelDirection` enum indicating the current locked drag direction (horizontal, vertical, or undecided).
    @Binding var directionLock: PanelDirection
    /// A binding to a CGFloat representing the scroll offset of the panel's content.
    @Binding var scrollOffset: CGFloat

    /// An array of CGFloat values defining the panel's snap points (min, default, max height).
    let snapPoints: [CGFloat]
    /// The minimum width the panel can shrink to.
    let minWidth: CGFloat
    /// The maximum width the panel can expand to.
    let maxWidth: CGFloat

    /// A version number for the panel's content, used to force updates.
    let version: Int
    /// A relay object to communicate panel version updates.
    let versionRelay: PanelVersionRelay
    /// A closure that provides the SwiftUI content to be displayed inside the panel.
    let content: () -> Content

    /// Creates and configures the `FloatingPanelController` (wrapped by `HostingControllerWrapper`).
    /// This method is called once by SwiftUI when the `AdaptivePanelUIKitHost` is first created.
    /// - Parameter context: The context provided by SwiftUI.
    /// - Returns: An instance of `UIViewController` that will manage the panel.
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = HostingControllerWrapper(
            isAtDefault: $isAtDefault,
            expansionProgress: $expansionProgress,
            isDraggingHorizontally: $isDraggingHorizontally,
            directionLock: $directionLock,
            scrollOffset: $scrollOffset,
            snapPoints: snapPoints,
            minWidth: minWidth,
            maxWidth: maxWidth,
            version: version,
            versionRelay: versionRelay,
            content: content
        )
        return controller
    }

    /// Updates the `FloatingPanelController` when SwiftUI's state changes.
    /// This method is called by SwiftUI when relevant `@Binding`s or `let` properties change.
    /// It ensures the `FloatingPanelController`'s content and internal state are synchronized with SwiftUI.
    /// - Parameters:
    ///   - uiViewController: The `UIViewController` instance to update.
    ///   - context: The context provided by SwiftUI.
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let controller = uiViewController as? HostingControllerWrapper<Content> else { return }
        
        // Always update content to ensure state changes are reflected
        // The content() closure will handle determining what to show
        controller.updateContent(content())
        
        // Update version tracking
        controller.version = version
    }

    // MARK: - Hosting Controller
    /// A wrapper class around `FloatingPanelController` to integrate it with SwiftUI's `UIViewControllerRepresentable`.
    /// This class allows the `FloatingPanelController` to receive SwiftUI content and bindings.
    class HostingControllerWrapper<WrappedContent: View>: FloatingPanelController<WrappedContent> {
        /// The current version of the panel's content.
        var version: Int
        /// The relay object for panel version updates.
        var versionRelay: PanelVersionRelay

        /// Required initializer for `NSCoder`, not used in this context.
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Initializes the `HostingControllerWrapper` with SwiftUI bindings and panel configuration.
        /// - Parameters:
        ///   - isAtDefault: A binding to a boolean indicating if the panel is at its default snap point.
        ///   - expansionProgress: A binding to a CGFloat representing the panel's expansion progress.
        ///   - isDraggingHorizontally: A binding to a boolean indicating horizontal drag state.
        ///   - directionLock: A binding to the current panel direction lock.
        ///   - scrollOffset: A binding to the scroll offset of the panel's content.
        ///   - snapPoints: An array of CGFloat values defining the panel's snap points.
        ///   - minWidth: The minimum width the panel can shrink to.
        ///   - maxWidth: The maximum width the panel can expand to.
        ///   - version: The initial version number for the panel's content.
        ///   - versionRelay: The relay object for panel version updates.
        ///   - content: A closure that provides the SwiftUI content for the panel.
        init(
            isAtDefault: Binding<Bool>,
            expansionProgress: Binding<CGFloat>,
            isDraggingHorizontally: Binding<Bool>,
            directionLock: Binding<PanelDirection>,
            scrollOffset: Binding<CGFloat>,
            snapPoints: [CGFloat],
            minWidth: CGFloat,
            maxWidth: CGFloat,
            version: Int,
            versionRelay: PanelVersionRelay,
            @ViewBuilder content: @escaping () -> WrappedContent
        ) {
            self.version = version
            self.versionRelay = versionRelay
            super.init(
                isAtDefault: isAtDefault,
                expansionProgress: expansionProgress,
                isDraggingHorizontally: isDraggingHorizontally,
                directionLock: directionLock,
                scrollOffset: scrollOffset,
                snapPoints: snapPoints,
                minWidth: minWidth,
                maxWidth: maxWidth,
                content: content
            )
        }

        /// Overrides the `updateContent` method from `FloatingPanelController` to update the SwiftUI `rootView`.
        /// This method is called by `AdaptivePanelUIKitHost`'s `updateUIViewController`.
        /// - Parameter newContent: The new SwiftUI content to display in the panel.
        override func updateContent(_ newContent: WrappedContent) {
            super.updateContent(newContent)
        }
    }
}
