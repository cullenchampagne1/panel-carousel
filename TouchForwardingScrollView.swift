import SwiftUI

/// A custom `UIScrollView` subclass that can forward its pan gestures to an external handler.
/// This is useful for scenarios where a parent view needs to intercept or coordinate with the scroll view's gestures.
class ForwardingScrollView<Content: View>: UIScrollView, UIGestureRecognizerDelegate {
    /// The `UIHostingController` that holds the SwiftUI content within this scroll view.
    var hostingController: UIHostingController<Content>?
    /// An optional closure that receives the scroll view's pan gestures.
    var externalPanHandler: ((UIPanGestureRecognizer) -> Void)?
    /// An optional `ScrollOffsetTracker` to publish the current scroll offset.
    var offsetTracker: ScrollOffsetTracker?
    
    /// Initializes a new `ForwardingScrollView` with a given frame.
    /// - Parameter frame: The frame of the scroll view.
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    /// Initializes a new `ForwardingScrollView` from a coder.
    /// - Parameter coder: The coder to decode from.
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    /// Performs initial setup for the scroll view, including gesture recognizer configuration.
    private func setup() {
        panGestureRecognizer.delegate = self
        panGestureRecognizer.addTarget(self, action: #selector(forwardPan(_:)))
    }
    
    /// Called when the view lays out its subviews.
    /// It updates the `offsetY` in the `offsetTracker` if available.
    override func layoutSubviews() {
        super.layoutSubviews()
        if let tracker = offsetTracker {
            DispatchQueue.main.async {
                tracker.offsetY = self.contentOffset.y
            }
        }
    }
    
    /// Forwards the pan gesture to the `externalPanHandler`.
    /// - Parameter gesture: The `UIPanGestureRecognizer` to forward.
    @objc private func forwardPan(_ gesture: UIPanGestureRecognizer) {
        externalPanHandler?(gesture)
    }
    
    /// Asks the delegate if a gesture recognizer should be allowed to recognize gestures simultaneously with another gesture recognizer.
    /// - Parameters:
    ///   - gestureRecognizer: The gesture recognizer that is asking.
    ///   - other: The other gesture recognizer.
    /// - Returns: `true` if both gesture recognizers should be allowed to recognize gestures simultaneously, otherwise `false`.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}

/// A SwiftUI `UIViewRepresentable` that wraps a `ForwardingScrollView`.
/// This struct allows SwiftUI views to embed a `UIScrollView` that can forward its pan gestures.
public struct TouchForwardingScrollView<Content: View>: UIViewRepresentable {
    /// A binding to an integer representing the current scroll step.
    @Binding public var scrollStep: Int
    /// A closure that provides the SwiftUI content for the scroll view.
    public let content: () -> Content
    /// An optional closure that receives the scroll view's pan gestures.
    public let externalPanHandler: ((UIPanGestureRecognizer) -> Void)?
    /// An `ObservableObject` to track and publish the scroll offset.
    public let offsetTracker: ScrollOffsetTracker

    /// Initializes a `TouchForwardingScrollView`.
    /// - Parameters:
    ///   - externalPanHandler: An optional closure to handle external pan gestures.
    ///   - offsetTracker: An `ObservableObject` to track the scroll offset.
    ///   - scrollStep: A binding to an integer representing the current scroll step.
    ///   - content: A closure that provides the SwiftUI content for the scroll view.
    public init(
        externalPanHandler: ((UIPanGestureRecognizer) -> Void)? = nil,
        offsetTracker: ScrollOffsetTracker,
        scrollStep: Binding<Int>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._scrollStep = scrollStep
        self.externalPanHandler = externalPanHandler
        self.offsetTracker = offsetTracker
        self.content = content
    }
    
    /// Creates and configures the `UIScrollView` (wrapped by `ForwardingScrollView`).
    /// This method is called once by SwiftUI when the `TouchForwardingScrollView` is first created.
    /// - Parameter context: The context provided by SwiftUI.
    /// - Returns: An instance of `UIScrollView` that will host the content.
    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ForwardingScrollView<Content>()
        scrollView.offsetTracker = offsetTracker
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.alwaysBounceVertical = true
        scrollView.bounces = true
        scrollView.externalPanHandler = externalPanHandler
        
        let hosting = UIHostingController(rootView: content())
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .clear
        
        scrollView.addSubview(hosting.view)
        scrollView.hostingController = hosting
        
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hosting.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        
        return scrollView
    }
    
    /// Updates the `UIScrollView` when SwiftUI's state changes.
    /// This method ensures the hosted SwiftUI content is up-to-date.
    /// - Parameters:
    ///   - uiView: The `UIScrollView` instance to update.
    ///   - context: The context provided by SwiftUI.
    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        guard let scrollView = uiView as? ForwardingScrollView<Content>,
              let hostingController = scrollView.hostingController else { return }
        hostingController.rootView = content()
        scrollView.externalPanHandler = externalPanHandler
    }
}

/// An `ObservableObject` to track and publish the scroll offset of a `UIScrollView`.
public final class ScrollOffsetTracker: ObservableObject {
    /// The current vertical scroll offset.
    @Published public var offsetY: CGFloat = 0
}