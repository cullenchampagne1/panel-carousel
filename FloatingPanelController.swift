import SwiftUI
import UIKit

/// An abstract `UIViewController` that manages a floating, draggable panel.
/// This class handles the panel's sizing, positioning, and gesture interactions.
/// It hosts SwiftUI content within a `UIHostingController`.
class FloatingPanelController<Content: View>: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    
    // MARK: - Bindings
    /// A binding to a boolean indicating if the panel is at its default (collapsed) snap point.
    var isAtDefault: Binding<Bool>
    /// A binding to a CGFloat representing the panel's expansion progress (0.0 to 1.0).
    var expansionProgress: Binding<CGFloat>
    /// A binding to a boolean indicating if the panel is currently being dragged horizontally.
    var isDraggingHorizontally: Binding<Bool>
    /// A binding to a `PanelDirection` enum indicating the current locked drag direction (horizontal, vertical, or undecided).
    var directionLock: Binding<PanelDirection>
    /// A binding to a CGFloat representing the scroll offset of the panel's content.
    var scrollOffset: Binding<CGFloat>
    
    /// An optional closure that is called when the scroll offset of the hosted content changes.
    var onScrollOffsetChanged: ((CGFloat) -> Void)?

    // MARK: - Panel Sizing
    /// An array of CGFloat values defining the panel's snap points (min, default, max height).
    private let snapPoints: [CGFloat]
    /// The minimum width the panel can shrink to.
    private let minWidth: CGFloat
    /// The maximum width the panel can expand to.
    private let maxWidth: CGFloat
    /// The minimum height of the panel, derived from `snapPoints`.
    private var minHeight: CGFloat     { snapPoints[0] }
    /// The default height of the panel, derived from `snapPoints`.
    private var defaultHeight: CGFloat { snapPoints[1] }
    /// The maximum height of the panel, derived from `snapPoints`.
    private var maxHeight: CGFloat     { snapPoints[2] }

    // MARK: - Views & Constraints
    /// The main view that represents the panel's background and shape.
    private let panelView = UIView()
    /// A clipping view to ensure content stays within the panel's bounds.
    private let clipView  = UIView()
    /// The height constraint for the panel's view.
    private var panelHeightConstraint: NSLayoutConstraint!
    /// The width constraint for the panel's view.
    private var panelWidthConstraint:  NSLayoutConstraint!
    /// The `UIHostingController` that hosts the SwiftUI content within the panel.
    let hostingController: UIHostingController<Content>

    // MARK: - Gesture State
    /// A weak reference to the `UIScrollView` found within the hosted SwiftUI content.
    private weak var scrollView: UIScrollView?
    /// The pan gesture recognizer attached to the panel view for vertical dragging.
    private var panelPan: UIPanGestureRecognizer!
    /// The height of the panel when a drag gesture begins.
    private var panelDragStartHeight: CGFloat = 0

    // MARK: - Optimized State Tracking
    /// The last reported scroll offset of the hosted content.
    private var lastScrollOffset: CGFloat = 0
    /// A flag to prevent multiple momentum handoffs during a single scroll deceleration.
    private var handoffOccurred = false
    /// The timestamp of the last binding update, used for throttling.
    private var lastBindingUpdate: TimeInterval = 0
    /// The minimum time interval between binding updates to prevent excessive updates (120fps max).
    private let bindingUpdateThrottle: TimeInterval = 1.0/120.0
    
    // MARK: - Cached Values
    /// Cached expansion progress for batched binding updates.
    private var cachedExpansionProgress: CGFloat = 0
    /// Cached width for batched binding updates.
    private var cachedWidth: CGFloat = 0
    /// Cached boolean indicating if the panel is at its default height.
    private var cachedIsAtDefault: Bool = true
    /// A flag indicating if bindings need to be updated.
    private var needsBindingUpdate: Bool = false
    
    // MARK: - Performance optimizations removed

    // MARK: - Initialization
    /// Initializes the `FloatingPanelController` with bindings and configuration.
    /// - Parameters:
    ///   - isAtDefault: A binding to a boolean indicating if the panel is at its default snap point.
    ///   - expansionProgress: A binding to a CGFloat representing the panel's expansion progress.
    ///   - isDraggingHorizontally: A binding to a boolean indicating horizontal drag state.
    ///   - directionLock: A binding to the current panel direction lock.
    ///   - scrollOffset: A binding to the scroll offset of the panel's content.
    ///   - snapPoints: An array of CGFloat values defining the panel's snap points.
    ///   - minWidth: The minimum width the panel can shrink to.
    ///   - maxWidth: The maximum width the panel can expand to.
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
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isAtDefault = isAtDefault
        self.expansionProgress = expansionProgress
        self.isDraggingHorizontally = isDraggingHorizontally
        self.directionLock = directionLock
        self.scrollOffset = scrollOffset
        self.snapPoints = snapPoints
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.cachedWidth = minWidth
        self.hostingController = UIHostingController(rootView: content())
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }
    
    /// Required initializer for `NSCoder`, not used in this context.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle
    /// Called after the controller's view is loaded into memory.
    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupGestures()
    }
    
    /// Called when the view is about to be added to a view hierarchy and before any animations are configured.
    /// - Parameter animated: If true, the view is being added to the window using an animation.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        locateScrollView()
        updatePanelConstraints(height: defaultHeight, width: minWidth, animated: false)
    }

    // MARK: - Setup
    /// Configures the panel's visual appearance and adds it to the view hierarchy.
    private func setupViews() {
        view.backgroundColor = .clear
        hostingController.view.backgroundColor = .clear

        panelView.backgroundColor = .black
        panelView.layer.cornerRadius = 14
        panelView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panelView.clipsToBounds = true

        clipView.clipsToBounds = true
        clipView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        view.addSubview(panelView)
        panelView.addSubview(clipView)
        clipView.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)

        [panelView, clipView, hostingController.view].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        
        panelWidthConstraint  = panelView.widthAnchor.constraint(equalToConstant: minWidth)
        panelHeightConstraint = panelView.heightAnchor.constraint(equalToConstant: defaultHeight)
        
        // Set lower priority to prevent constraint conflicts when height goes negative
        panelHeightConstraint.priority = UILayoutPriority(999)
        
        let handle = UIView()
        handle.backgroundColor = UIColor.gray.withAlphaComponent(0.18)
        handle.layer.cornerRadius = 2.5
        handle.translatesAutoresizingMaskIntoConstraints = false
        panelView.addSubview(handle)
        
        NSLayoutConstraint.activate([
            handle.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 12),
            handle.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            handle.widthAnchor.constraint(equalToConstant: 65),
            handle.heightAnchor.constraint(equalToConstant: 5),
            
            panelWidthConstraint!,
            panelHeightConstraint!,
            panelView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            clipView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            clipView.topAnchor.constraint(equalTo: panelView.topAnchor),
            clipView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            hostingController.view.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: clipView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: clipView.bottomAnchor)
        ])
        
        panelView.bringSubviewToFront(handle)
    }
    
    /// Sets up the pan gesture recognizer for the panel.
    private func setupGestures() {
        panelPan = UIPanGestureRecognizer(target: self, action: #selector(handlePanelPan(_:)))
        panelPan.delegate = self
        panelView.addGestureRecognizer(panelPan)
    }
    
    /// Locates the `UIScrollView` within the hosted SwiftUI content and sets its delegate.
    private func locateScrollView() {
        guard let sv = findScrollView(in: hostingController.view) else { return }
        scrollView = sv
        sv.delegate = self
        sv.alwaysBounceVertical = false
        sv.bounces = false
    }
    
    /// Recursively searches for a `UIScrollView` within a given view hierarchy.
    /// - Parameter view: The view to start searching from.
    /// - Returns: The first `UIScrollView` found, or `nil` if none is found.
    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView { return sv }
        return view.subviews.compactMap(findScrollView).first
    }
    
    // MARK: - UIScrollViewDelegate
    /// Called when the scroll view is about to begin scrolling the content.
    /// - Parameter scrollView: The scroll view that is about to scroll.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = directionLock.wrappedValue == .vertical
        handoffOccurred = false
    }

    /// Called when the scroll view is scrolling its content.
    /// This method updates the panel's height and width based on scroll progress.
    /// - Parameter scrollView: The scroll view that is scrolling.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        
        // Calculate expansion with clamping
        let contentMax = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let expandedOffset = min(max(offset, 0), contentMax)
        let expansionAmount = maxHeight - defaultHeight
        let progress = min(expandedOffset, expansionAmount) / expansionAmount
        let height = defaultHeight + expansionAmount * progress
        
        // Update both height and width constraints immediately for smooth animation
        panelHeightConstraint.constant = height
        
        // Update width based on expansion progress (matching original logic)
        let widthProgress = max(0, min(progress, 1))
        let newWidth = minWidth + (maxWidth - minWidth) * widthProgress
        if abs(newWidth - cachedWidth) > 0.5 {
            panelWidthConstraint.constant = newWidth
            cachedWidth = newWidth
        }
        
        // Cache values for batched binding updates
        cachedExpansionProgress = progress
        lastScrollOffset = offset
        needsBindingUpdate = true
        
        // Throttled binding updates
        scheduleBindingUpdateIfNeeded()
        
        // Simplified momentum handoff
        if scrollView.isDecelerating && !handoffOccurred && offset <= 0 && lastScrollOffset > 0 {
            handoffMomentumToPanel()
            handoffOccurred = true
        }
        
        onScrollOffsetChanged?(offset)
    }
    
    /// Schedules a binding update if needed, throttling updates to prevent excessive UI refreshes.
    private func scheduleBindingUpdateIfNeeded() {
        let now = CACurrentMediaTime()
        guard needsBindingUpdate && (now - lastBindingUpdate) >= bindingUpdateThrottle else { return }
        
        needsBindingUpdate = false
        lastBindingUpdate = now
        
        // Batch all binding updates
        updateBindingsFromCache()
    }

    /// Handles momentum handoff from the scroll view to the panel when scrolling up past the top.
    private func handoffMomentumToPanel() {
        guard directionLock.wrappedValue == .vertical else { return }
        
        let overshoot: CGFloat = 150 // Simplified constant
        animateToHeight(defaultHeight - overshoot, then: defaultHeight, velocity: -500)
    }

    /// Called when the user finishes scrolling the content.
    /// - Parameters:
    ///   - scrollView: The scroll view that is scrolling.
    ///   - velocity: The velocity of the scroll view in points per second.
    ///   - targetContentOffset: The point at which the scrolling is expected to stop.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        scrollView.isScrollEnabled = true
        
        guard scrollView.contentOffset.y <= 0, velocity.y < 0 else { return }
        
        let overshoot = min(max(abs(velocity.y) * 60, 30), 350)
        animateToHeight(defaultHeight - overshoot, then: defaultHeight, velocity: velocity.y)
    }

    // MARK: - Optimized Panel Dragging
    /// Handles the pan gesture for dragging the panel vertically.
    /// - Parameter gesture: The `UIPanGestureRecognizer` that triggered the action.
    @objc private func handlePanelPan(_ gesture: UIPanGestureRecognizer) {
        guard directionLock.wrappedValue == .vertical,
              let scrollView = scrollView else {
            return 
        }
        
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view).y

        switch gesture.state {
        case .began:
            panelDragStartHeight = panelHeightConstraint.constant

        case .changed:
            // Only pull if scroll is at top and dragging down
            guard scrollView.contentOffset.y <= 0 && translation.y > 0 else { return }
            
            let newHeight = panelDragStartHeight - translation.y
            // Allow negative heights during drag for gesture detection, but clamp in updatePanelConstraints
            updatePanelConstraints(height: newHeight, animated: false)

        case .ended, .cancelled:
            if panelHeightConstraint.constant < defaultHeight {
                animateToHeight(defaultHeight, velocity: velocity)
            } else {
                resetDirectionLock()
            }

        default: break
        }
    }

    // MARK: - Consolidated Animation System
    /// Animates the panel to a target height using a spring animation.
    /// - Parameters:
    ///   - targetHeight: The final height for the panel.
    ///   - finalHeight: An optional final height to animate to after the initial animation completes.
    ///   - velocity: The initial velocity for the spring animation.
    private func animateToHeight(_ targetHeight: CGFloat, then finalHeight: CGFloat? = nil, velocity: CGFloat = 0) {
        let spring = UISpringTimingParameters(
            dampingRatio: 0.75,
            initialVelocity: CGVector(dx: 0, dy: velocity / 1000)
        )
        
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
        
        animator.addAnimations {
            self.updatePanelConstraints(height: targetHeight, animated: true)
        }
        
        if let finalHeight = finalHeight {
            animator.addCompletion { _ in
                self.animateToHeight(finalHeight, velocity: 0)
            }
        } else {
            animator.addCompletion { _ in
                self.resetDirectionLock()
            }
        }
        
        animator.startAnimation()
    }
    
    /// Updates the panel's height and width constraints.
    /// - Parameters:
    ///   - height: The new height for the panel.
    ///   - width: An optional new width for the panel. If nil, width is calculated based on expansion progress.
    ///   - animated: A boolean indicating whether to animate the constraint changes.
    private func updatePanelConstraints(height: CGFloat, width: CGFloat? = nil, animated: Bool = true) {
        panelHeightConstraint.constant = height
        
        if let width = width {
            panelWidthConstraint.constant = width
            cachedWidth = width
        } else {
            // Calculate width based on expansion progress
            let delta = height - defaultHeight
            let progress = delta >= 0 ?
                min(delta / (maxHeight - defaultHeight), 1) :
                -min(-delta / (defaultHeight - minHeight), 1)
            
            let newWidth = minWidth + (maxWidth - minWidth) * max(0, min(progress, 1))
            // Always update width constraint - the small change optimization was causing issues
            panelWidthConstraint.constant = newWidth
            cachedWidth = newWidth
        }
        
        if animated {
            view.layoutIfNeeded()
        }
        
        // Update cached values
        updateCachedValues(height: height)
        needsBindingUpdate = true
        scheduleBindingUpdateIfNeeded()
    }
    
    /// Updates cached values for expansion progress and default state.
    /// - Parameter height: The current height of the panel.
    private func updateCachedValues(height: CGFloat) {
        cachedIsAtDefault = abs(height - defaultHeight) < 1
        
        let delta = height - defaultHeight
        cachedExpansionProgress = delta >= 0 ?
            min(delta / (maxHeight - defaultHeight), 1) :
            -min(-delta / (defaultHeight - minHeight), 1)
    }
    
    /// Dispatches binding updates to the main queue, ensuring they are batched and throttled.
    private func updateBindingsFromCache() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isAtDefault.wrappedValue = self.cachedIsAtDefault
            self.expansionProgress.wrappedValue = self.cachedExpansionProgress
            self.scrollOffset.wrappedValue = self.lastScrollOffset
        }
    }
    
    /// Resets the panel's direction lock to undecided.
    private func resetDirectionLock() {
        directionLock.wrappedValue = .undecided
    }

    /// Updates the SwiftUI content hosted within the panel.
    /// - Parameter newContent: The new SwiftUI content to display.
    func updateContent(_ newContent: Content) {
        hostingController.rootView = newContent
    }

    // MARK: - UIGestureRecognizerDelegate
    /// Asks the delegate if a gesture recognizer should be allowed to recognize gestures simultaneously with another gesture recognizer.
    /// - Parameters:
    ///   - gestureRecognizer: The gesture recognizer that is asking.
    ///   - other: The other gesture recognizer.
    /// - Returns: `true` if both gesture recognizers should be allowed to recognize gestures simultaneously, otherwise `false`.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true
    }
}