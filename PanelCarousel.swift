import SwiftUI
import Foundation
import Combine
import SDWebImage

// MARK: - Supporting Types
/// An enumeration representing the possible directions of panel dragging.
public enum PanelDirection {
    case undecided, horizontal, vertical
}

/// An enumeration representing the state of a panel within the carousel.
public enum PanelState {
    case active, frozen
}

/// A struct used as a key for caching panel views, combining index and version.
private struct PanelCacheKey: Hashable {
    let idx: Int
    let version: Int
}

/// A protocol defining the interface for a carousel data loader.
/// Implement this protocol to provide data and views to the `PanelCarousel`.
public protocol CarouselLoader: ObservableObject {
    associatedtype DataItem: Identifiable
    
    /// The array of data items to be displayed in the carousel.
    var items: [DataItem] { get set }
    /// A dictionary tracking the loading state of individual items.
    var itemLoadingStates: [Int: Bool] { get set }
    
    /// Checks if the basic data for a given item is loaded.
    /// - Parameter item: The data item to check.
    /// - Returns: `true` if the basic data is loaded, `false` otherwise.
    func isDataLoaded(for item: DataItem) -> Bool
    
    /// Checks if all necessary data for a given item and version is ready for display.
    /// This is used to determine whether to show a loading view or the actual content.
    /// - Parameters:
    ///   - item: The data item to check.
    ///   - version: The version of the panel content.
    /// - Returns: `true` if all data is ready, `false` otherwise.
    func isAllDataReady(for item: DataItem, version: Int) -> Bool
    
    /// Creates a loading view for a given data item.
    /// - Parameters:
    ///   - item: The data item for which to create the loading view.
    ///   - message: A message to display in the loading view.
    /// - Returns: An `AnyView` representing the loading state.
    func createLoadingView(for item: DataItem, message: String) -> AnyView
    
    /// Creates the fully loaded content view for a given data item.
    /// - Parameters:
    ///   - item: The data item for which to create the content view.
    ///   - index: The index of the item in the carousel.
    ///   - version: The version of the panel content.
    ///   - versionRelay: A relay object to trigger panel reloads.
    ///   - scrollStep: A binding to an integer representing the scroll step of the panel's content.
    /// - Returns: An `AnyView` representing the loaded content.
    func createLoadedContentView(for item: DataItem, at index: Int, version: Int, versionRelay: PanelVersionRelay, scrollStep: Binding<Int>) -> AnyView
    
    /// Loads initial data for the carousel, typically for the currently selected item.
    /// - Parameter initialIndex: The index of the initially selected item.
    func loadInitialData(initialIndex: Int) async
    
    /// Loads data for a specific item with high priority.
    /// - Parameter index: The index of the item to load.
    func loadItemWithPriority(at index: Int) async
    
    /// Loads data for a range of items.
    /// - Parameter indices: An array of indices of items to load.
    func loadItemRange(indices: [Int]) async
    
    /// Triggers a full reload of all data managed by the loader.
    func triggerFullReload()
    
    /// Cleans up memory associated with the loader's data.
    func cleanupMemory()
}

/// A struct defining configuration parameters for the `PanelCarousel`.
public struct CarouselConfiguration {
    /// An array of CGFloat values defining the panel's snap points (min, default, max height).
    public let snapPoints: [CGFloat]
    /// The minimum width the panel can shrink to.
    public let minWidth: CGFloat
    /// The maximum width the panel can expand to.
    public let maxWidth: CGFloat
    /// The base gap between panels when collapsed.
    public let baseGap: CGFloat
    /// The maximum gap between panels when expanded.
    public let maxGap: CGFloat
    /// The amount to shrink inactive panels.
    public let inactiveShrink: CGFloat
    /// The animation to use for panel transitions.
    public let animation: Animation
    /// Scroll thresholds for tracking panel scroll progress.
    public let scrollThresholds: [CGFloat]

    /// Default configuration for a game panel.
    public static let gamePanel = CarouselConfiguration(
        snapPoints: [
            UIScreen.main.bounds.height * 0.25,
            UIScreen.main.bounds.height * 0.85,
            UIScreen.main.bounds.height * 1.0
        ],
        minWidth: UIScreen.main.bounds.width * 0.91,
        maxWidth: UIScreen.main.bounds.width * 1.0,
        baseGap: 18,
        maxGap: 52,
        inactiveShrink: 28,
        animation: .interactiveSpring(response: 0.5, dampingFraction: 0.89),
        scrollThresholds: [60, 90, 500]
    )
}

/// Observable object that manages panel version updates and reload notifications.
public class PanelVersionRelay: ObservableObject {
    /// Published property that triggers panel reloads when changed.
    @Published public var reloadID: Int = -1
    
    /// Triggers a reload for a specific panel index.
    /// - Parameter idx: The index of the panel to reload.
    public func reloadPanel(_ idx: Int) { reloadID = idx }
}

/// A generic carousel view that displays panels with adaptive expansion and horizontal scrolling.
/// Supports priority loading, persistent panel hosts, and optimized data management.
/// Uses `CarouselLoader` protocol for extensible data loading and view creation.
public struct PanelCarousel<Loader: CarouselLoader>: View {
    
    // MARK: - Configuration Properties
    /// The initial item index to display when the carousel appears.
    public let initialItemIndex: Int
    /// The carousel loader responsible for data loading and view creation.
    @ObservedObject public var loader: Loader
    /// Optional closure called when the carousel is closed.
    public let onClose: (() -> Void)?
    /// Configuration for carousel behavior and appearance.
    public let configuration: CarouselConfiguration

    // MARK: - Core State Management
    /// Version relay for managing panel reloads and updates.
    @StateObject private var versionRelay = PanelVersionRelay()
    /// Currently selected panel index.
    @State private var selected: Int
    
    // MARK: - Panel State Arrays
    /// Array tracking whether each panel is at its default (collapsed) state.
    @State private var atDefaultStates: [Bool]
    /// Array tracking expansion progress for each panel (0.0 to 1.0).
    @State private var progressStates: [CGFloat]
    /// Array tracking scroll offsets for each panel's content.
    @State private var scrollOffsets: [CGFloat]
    /// Dictionary tracking scroll step progress for each panel.
    @State private var panelScrollSteps: [Int: Int] = [:]
    
    // MARK: - Data Caching System
    /// Panel versions for tracking updates and reloads.
    @State private var panelVersions: [Int: Int] = [:]
    
    // MARK: - Gesture State Management
    /// Current horizontal drag offset during gesture.
    @State private var dragOffset: CGFloat = 0
    /// Flag indicating whether horizontal dragging is active.
    @State private var isDraggingHorizontally = false
    /// Direction lock for gesture handling (horizontal/vertical/undecided).
    @State private var directionLock: PanelDirection = .undecided
    /// Frozen expansion value during horizontal drag to maintain panel state.
    @State private var frozenExpansion: CGFloat? = nil

    // MARK: - Animation State
    /// Controls background visibility animation.
    @State private var bgVisible = false
    /// Controls carousel visibility animation.
    @State private var carouselVisible = false
    /// Flag to track if this is initial load or user interaction.
    @State private var isInitialLoad = true
    /// Set of panel indices that are allowed to show loaded content.
    @State private var allowedToShowContent: Set<Int> = []
    
    // MARK: - Panel Host Management
    /// Cached AdaptivePanelHost instances to prevent recreation during drag gestures.
    @State private var panelHosts: [String: AnyView] = [:]
    
    // MARK: - Configuration Constants
    /// Scroll thresholds for tracking panel scroll progress.
    private var scrollThresholds: [CGFloat] { configuration.scrollThresholds }
    /// Base gap between panels when collapsed.
    private var baseGap: CGFloat { configuration.baseGap }
    /// Maximum gap between panels when expanded.
    private var maxGap: CGFloat { configuration.maxGap }
    /// Amount to shrink inactive panels.
    private var inactiveShrink: CGFloat { configuration.inactiveShrink }
    /// Animation configuration for panel transitions.
    private var animation: Animation { configuration.animation }

    // MARK: - Initialization
    /// Initializes the generic panel carousel with specified configuration.
    /// - Parameters:
    ///   - loader: The carousel loader for data management.
    ///   - startIndex: Initial item index to display (default: 0).
    ///   - configuration: Configuration for carousel behavior.
    ///   - onClose: Optional closure called when carousel is closed.
    public init(
        loader: Loader,
        startIndex: Int = 0,
        configuration: CarouselConfiguration = .gamePanel,
        onClose: (() -> Void)? = nil
    ) {
        self.initialItemIndex = startIndex
        self.loader = loader
        self.configuration = configuration
        _selected = State(initialValue: 0)
        _atDefaultStates = State(initialValue: [])
        _progressStates = State(initialValue: [])
        _scrollOffsets = State(initialValue: [])
        self.onClose = onClose
    }

    // MARK: - Data Access Methods
    /// Checks if all required data is loaded for a specific item.
    /// - Parameter item: The data item to check.
    /// - Returns: True if all data is available.
    private func isDataLoadedForItem(_ item: Loader.DataItem) -> Bool {
        return loader.isDataLoaded(for: item)
    }
    
    /// Creates bindings for a specific panel index.
    /// - Parameter idx: The panel index to create bindings for.
    /// - Returns: Tuple of bindings for panel state management.
    private func createPanelBindings(for idx: Int) -> (isAtDefault: Binding<Bool>, progress: Binding<CGFloat>, scrollOffset: Binding<CGFloat>, scrollStep: Binding<Int>) {
        let isAtDefaultBinding = Binding<Bool>(
            get: { self.atDefaultStates.indices.contains(idx) ? self.atDefaultStates[idx] : true },
            set: { if self.atDefaultStates.indices.contains(idx) { self.atDefaultStates[idx] = $0 } }
        )
        let progressBinding = Binding<CGFloat>(
            get: { self.progressStates.indices.contains(idx) ? self.progressStates[idx] : 0.0 },
            set: { if self.progressStates.indices.contains(idx) { self.progressStates[idx] = $0 } }
        )
        let scrollOffsetBinding = Binding<CGFloat>(
            get: { self.scrollOffsets.indices.contains(idx) ? self.scrollOffsets[idx] : 0.0 },
            set: { if self.scrollOffsets.indices.contains(idx) { self.scrollOffsets[idx] = $0 } }
        )
        let scrollStepBinding = Binding<Int>(
            get: { self.panelScrollSteps[idx] ?? -1 },
            set: { self.panelScrollSteps[idx] = $0 }
        )
        
        return (isAtDefaultBinding, progressBinding, scrollOffsetBinding, scrollStepBinding)
    }
    
    /// Checks if all data is ready for a specific panel version with caching.
    /// - Parameters:
    ///   - item: The data item to check.
    ///   - version: The panel version number.
    /// - Returns: True if data is ready and cached.
    private func isAllDataReadyForPanel(item: Loader.DataItem, version: Int) -> Bool {
        return loader.isAllDataReady(for: item, version: version)
    }
    
    /// Creates a loading view using the loader's implementation.
    /// - Parameters:
    ///   - item: The data item for the loading view.
    ///   - message: Loading message to display.
    /// - Returns: A view showing loading state.
    private func createLoadingView(for item: Loader.DataItem, message: String) -> AnyView {
        return loader.createLoadingView(for: item, message: message)
    }
    
    /// Creates or retrieves cached AdaptivePanelHost for a panel index.
    /// - Parameters:
    ///   - index: The index of the panel.
    ///   - item: The data item associated with the panel.
    ///   - bindings: A tuple of bindings for the panel's state management.
    /// - Returns: An `AnyView` containing the `AdaptivePanelUIKitHost`.
    private func createPanelHost(for index: Int, item: Loader.DataItem, bindings: (isAtDefault: Binding<Bool>, progress: Binding<CGFloat>, scrollOffset: Binding<CGFloat>, scrollStep: Binding<Int>)) -> AnyView {
        let version = panelVersions[index, default: 0]
        let isDataReady = loader.isAllDataReady(for: item, version: version)
        let isAllowed = allowedToShowContent.contains(index)
        let isLoaded = isDataReady && isAllowed
        
        // Cache key includes both index and loading state to recreate only when content type changes
        let cacheKey = "\(index)_v\(version)_\(isLoaded ? "loaded" : "loading")"
        if let cachedHost = panelHosts[cacheKey] { return cachedHost }
        
        let host = createAdaptivePanelHost(
            content: getCurrentPanelContent(for: index, item: item, version: version),
            isAtDefault: bindings.isAtDefault,
            expansionProgress: bindings.progress,
            isDraggingHorizontally: $isDraggingHorizontally,
            directionLock: $directionLock,
            scrollOffset: bindings.scrollOffset,
            version: version,
            versionRelay: versionRelay
        )
        
        let hostView = AnyView(host)
        
        // Cache without modifying state during view building
        Task { @MainActor in
            if panelHosts[cacheKey] == nil {
                panelHosts[cacheKey] = hostView
            }
        }
        
        return hostView
    }
    
    /// Gets the current content for a panel (loading or loaded).
    /// - Parameters:
    ///   - index: The index of the panel.
    ///   - item: The data item associated with the panel.
    ///   - version: The version of the panel content.
    /// - Returns: An `AnyView` representing the panel's content (loading or loaded).
    private func getCurrentPanelContent(for index: Int, item: Loader.DataItem, version: Int) -> AnyView {
        let scrollStepBinding = Binding<Int>(
            get: { panelScrollSteps[index] ?? -1 },
            set: { panelScrollSteps[index] = $0 }
        )
        
        let isDataReady = loader.isAllDataReady(for: item, version: version)
        let isAllowed = allowedToShowContent.contains(index)
        
        // Show loaded content if data is ready and allowed
        if isDataReady && isAllowed {
            return loader.createLoadedContentView(
                for: item,
                at: index,
                version: version,
                versionRelay: versionRelay,
                scrollStep: scrollStepBinding
            )
        } else {
            return loader.createLoadingView(for: item, message: "Loading data...")
        }
    }
    
    /// Creates `AdaptivePanelUIKitHost` with persistent bindings.
    /// - Parameters:
    ///   - content: The SwiftUI content to host.
    ///   - isAtDefault: Binding to the panel's default state.
    ///   - expansionProgress: Binding to the panel's expansion progress.
    ///   - isDraggingHorizontally: Binding to the horizontal drag state.
    ///   - directionLock: Binding to the panel's direction lock.
    ///   - scrollOffset: Binding to the panel's scroll offset.
    ///   - version: The version of the panel content.
    ///   - versionRelay: The relay object for panel version updates.
    /// - Returns: An `AdaptivePanelUIKitHost` instance.
    private func createAdaptivePanelHost<Content: View>(
        content: Content,
        isAtDefault: Binding<Bool>,
        expansionProgress: Binding<CGFloat>,
        isDraggingHorizontally: Binding<Bool>,
        directionLock: Binding<PanelDirection>,
        scrollOffset: Binding<CGFloat>,
        version: Int,
        versionRelay: PanelVersionRelay
    ) -> some View {
        AdaptivePanelUIKitHost(
            isAtDefault: isAtDefault,
            expansionProgress: expansionProgress,
            isDraggingHorizontally: isDraggingHorizontally,
            directionLock: directionLock,
            scrollOffset: scrollOffset,
            snapPoints: configuration.snapPoints,
            minWidth: configuration.minWidth,
            maxWidth: configuration.maxWidth,
            version: version,
            versionRelay: versionRelay
        ) {
            content
        }
    }
    
    /// Loads initial carousel data with priority loading: current panel first, then cascade.
    private func loadInitialCarouselData() {
        guard !loader.items.isEmpty else { return }
        
        Task {
            await loader.loadInitialData(initialIndex: selected)
            // Start cascade delay in background without blocking UI
            Task.detached {
                await loadCascadeRange()
            }
        }
    }
    
    /// Loads a specific panel with priority.
    /// - Parameter index: The index of the panel to load.
    private func loadPanelWithPriority(at index: Int) async {
        guard loader.items.indices.contains(index) else { return }
        
        await loader.loadItemWithPriority(at: index)
        
        await MainActor.run {
            let currentVersion = panelVersions[index, default: 0]
            panelVersions[index] = currentVersion + 1
        }
    }
    
    /// Cascades loading to the load range (left and right of current panel).
    private func loadCascadeRange() async {
        let loadRange = [selected - 1, selected + 1].compactMap { idx in
            loader.items.indices.contains(idx) ? idx : nil
        }
        // Add 5 second delay before starting cascade loading
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 seconds delay
        
        print("🎆 Cascade delay finished - allowing adjacent panels to show content")
        
        await MainActor.run {
            // Allow adjacent panels to show loaded content after delay
            allowedToShowContent.formUnion(loadRange)
            
            // Force panel content updates for newly allowed panels
            for index in loadRange {
                let currentVersion = panelVersions[index, default: 0]
                panelVersions[index] = currentVersion + 1
            }
        }
        
        await loader.loadItemRange(indices: loadRange)
        
        await MainActor.run {
            for index in loadRange {
                let currentVersion = panelVersions[index, default: 0]
                panelVersions[index] = currentVersion + 1
            }
        }
    }
    
    
    /// Loads data for a specific panel with improved state management.
    /// - Parameter index: The index of the panel to load data for.
    private func loadDataForPanel(at index: Int) {
        guard loader.items.indices.contains(index) else { return }
        
        let item = loader.items[index]
        
        if !isDataLoadedForItem(item) {
            Task {
                await loader.loadItemWithPriority(at: index)
                await MainActor.run {
                    let currentVersion = panelVersions[index, default: 0]
                    panelVersions[index] = currentVersion + 1
                    }
            }
        }
    }
    
    /// Ensures visible panels have data with proper load range management.
    /// - Parameter immediate: If `true`, loads immediately; if `false`, respects initial load delay.
    private func ensureVisiblePanelsHaveData(immediate: Bool = false) {
        guard !loader.items.isEmpty else { return }
        
        // Visible range: selected +/- 1
        let visibleRange = max(0, selected - 1)...min(loader.items.count - 1, selected + 1)
        
        // Load range: selected +/- 2 (outer visible range)
        let loadRange = max(0, selected - 2)...min(loader.items.count - 1, selected + 2)
        
        // Keep outer visible range at load state until category switch
        Task { @MainActor in
            for idx in loadRange {
                if !visibleRange.contains(idx) {
                    // Keep at loading state for outer range
                    loader.itemLoadingStates[idx] = true
                }
            }
        }
        
        if immediate || !isInitialLoad {
            // Allow all visible panels to show loaded content immediately
            let newlyAllowed = visibleRange.filter { !allowedToShowContent.contains($0) }
            allowedToShowContent.formUnion(visibleRange)
            
            // Force updates for newly allowed panels
            for idx in newlyAllowed {
                let currentVersion = panelVersions[idx, default: 0]
                panelVersions[idx] = currentVersion + 1
            }
            
            // Load data immediately for user interactions
            Task {
                for idx in visibleRange {
                    let item = loader.items[idx]
                    let version = panelVersions[idx, default: 0]
                    if !isAllDataReadyForPanel(item: item, version: version) {
                        loadDataForPanel(at: idx)
                    }
                }
            }
        } else {
            // For initial load, only allow the selected panel to show loaded content
            let wasAllowed = allowedToShowContent.contains(selected)
            allowedToShowContent.insert(selected)
            
            // Force update if this panel wasn't previously allowed
            if !wasAllowed {
                let currentVersion = panelVersions[selected, default: 0]
                panelVersions[selected] = currentVersion + 1
            }
            
            // Adjacent panels will be allowed after cascade delay
            Task {
                let item = loader.items[selected]
                let version = panelVersions[selected, default: 0]
                if !isAllDataReadyForPanel(item: item, version: version) {
                    loadDataForPanel(at: selected)
                }
            }
        }
    }
    
    /// Triggers full load for category switch.
    private func triggerCategoryLoad() {
        // Reset all loading states
        loader.triggerFullReload()
        // Load visible range
        ensureVisiblePanelsHaveData()
    }
    
    /// Cleans up all panel memory and cached data.
    private func cleanupAllPanelMemory() {
        loader.cleanupMemory()
        panelHosts.removeAll()
    }

    /// Cleans up cache for panels that are no longer in the visible range.
    /// - Parameter newlySelected: The index of the newly selected panel.
    private func cleanupCacheForOffscreenPanels(newlySelected: Int) {
        let retentionRange = (newlySelected - 2)...(newlySelected + 2)

        for (index, _) in panelVersions {
            if !retentionRange.contains(index) {
                panelVersions.removeValue(forKey: index)
            }
        }

        for (key, _) in panelHosts {
            if let index = Int(key.split(separator: "_").first ?? "") {
                if !retentionRange.contains(index) {
                    panelHosts.removeValue(forKey: key)
                }
            }
        }
    }

    /// Creates a panel view for a specific index with proper positioning and state.
    /// - Parameters:
    ///   - idx: The panel index.
    ///   - geo: Geometry proxy for layout calculations.
    /// - Returns: Configured panel view.
    @ViewBuilder
    private func panel(for idx: Int, in geo: GeometryProxy) -> some View {
        let arraysInitialized = !loader.items.isEmpty &&
                               selected < progressStates.count &&
                               selected < atDefaultStates.count &&
                               selected < scrollOffsets.count
        let expansion = arraysInitialized ?
                       (isDraggingHorizontally ? (frozenExpansion ?? progressStates[selected]) : progressStates[selected]) : 0.0
        let gap = baseGap + (maxGap - baseGap) * expansion
        let cardDistance = geo.size.width - inactiveShrink + gap * expansion
        
        let isActive = idx == selected
        let shrink = isActive ? 0 : inactiveShrink
        let cardWidth = geo.size.width - shrink
        let drag = isDraggingHorizontally && directionLock == .horizontal ? dragOffset : 0
        let offset = CGFloat(idx - selected) * cardDistance + drag
        let item = loader.items[idx]
        let bindings = createPanelBindings(for: idx)
        
        createPanelHost(for: idx, item: item, bindings: bindings)
            .frame(width: cardWidth)
            .offset(x: offset)
            .zIndex(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .id(idx)
    }

    /// The main body of the `PanelCarousel` view.
    public var body: some View {
        content
    }
    
    /// The internal content view of the `PanelCarousel`.
    private var content: some View {
        GeometryReader { geo in
            let arraysInitialized = !loader.items.isEmpty && 
                                   selected < progressStates.count && 
                                   selected < atDefaultStates.count && 
                                   selected < scrollOffsets.count

            ZStack {
                Color.black.opacity(0.8)
                    .ignoresSafeArea()
                    .opacity(bgVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.32), value: bgVisible)

                ZStack {
                    if arraysInitialized {
                        let startIndex = max(0, selected - 2)
                        let endIndex = min(loader.items.count - 1, selected + 2)
                        let visibleIndices = Array(startIndex...endIndex)
                        
                        ForEach(visibleIndices, id: \.self) { idx in
                            panel(for: idx, in: geo)
                        }
                    }
                }
                .offset(y: (carouselVisible && arraysInitialized) ? 0 : geo.size.height * 1.25)
                .animation(.spring(response: 0.63, dampingFraction: 0.83), value: carouselVisible && arraysInitialized)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .animation(animation, value: selected)
            .onAppear {
                bgVisible = true
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    await MainActor.run {
                        carouselVisible = true
                    }
                }
            }
            .onReceive(versionRelay.$reloadID) { reloadIdx in
                guard reloadIdx >= 0 else { return }
                panelVersions[reloadIdx, default: 0] += 1
            }
            .onChange(of: selected) { newIdx, _ in
                if panelScrollSteps[newIdx] == nil {
                    panelScrollSteps[newIdx] = -1
                }
                
                cleanupCacheForOffscreenPanels(newlySelected: newIdx)

                Task {
                    isInitialLoad = false // Mark as user interaction
                    ensureVisiblePanelsHaveData(immediate: true)
                }
            }
            .onChange(of: progressStates.indices.contains(selected) ? progressStates[selected] : 0.0) { newValue, _ in
                if newValue < -0.1 && carouselVisible {
                    carouselVisible = false
                    cleanupAllPanelMemory()
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        await MainActor.run {
                            bgVisible = false
                        }
                        try? await Task.sleep(nanoseconds: 330_000_000) // Additional 330ms to total 680ms
                        await MainActor.run {
                            onClose?()
                        }
                    }
                }
            }
            .onChange(of: scrollOffsets.indices.contains(selected) ? scrollOffsets[selected] : 0.0) { scrollY, _ in
                guard !loader.items.isEmpty && selected < loader.items.count else { return }
                for (i, threshold) in scrollThresholds.enumerated() {
                    if scrollY > threshold && i > (panelScrollSteps[selected] ?? -1) {
                        panelScrollSteps[selected] = i
                        // By incrementing the version, we force the panel to be recreated,
                        // ensuring the new scrollStep value is recognized by the child view.
                        panelVersions[selected, default: 0] += 1
                        break
                    }
                }
            }
        }
        .onAppear {
            loadItemsFromCache()
        }
    }
    
    /// Drag gesture for horizontal panel navigation.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged(onDragChanged)
            .onEnded(onDragEnded)
    }
    
    /// Handles drag gesture changes with direction locking.
    /// - Parameter value: The drag gesture value.
    private func onDragChanged(_ value: DragGesture.Value) {
        if directionLock == .undecided {
            let absX = abs(value.translation.width)
            let absY = abs(value.translation.height)
            let thresh: CGFloat = 14
            if absX > thresh || absY > thresh {
                directionLock = absX > absY ? .horizontal : .vertical
                if directionLock == .horizontal {
                    guard selected < progressStates.count else { return }
                    let currentProgress = progressStates[selected]
                    // Update state immediately to avoid async issues
                    frozenExpansion = currentProgress
                    for i in atDefaultStates.indices {
                        atDefaultStates[i] = true
                        progressStates[i] = 0
                    }
                }
            }
        }
        if directionLock == .horizontal && selected < atDefaultStates.count && atDefaultStates[selected] {
            isDraggingHorizontally = true
            dragOffset = value.translation.width
        }
    }
    
    /// Handles drag gesture end with panel switching logic.
    /// - Parameter value: The drag gesture value.
    private func onDragEnded(_ value: DragGesture.Value) {
        guard directionLock == .horizontal, selected < atDefaultStates.count, atDefaultStates[selected] else {
            dragOffset = 0
            // Don't reset directionLock to .undecided if it's .vertical - let the panel handle it
            if directionLock == .horizontal {
                directionLock = .undecided
            }
            return
        }
        let drag = value.translation.width
        let threshold: CGFloat = 80
        var newIdx = selected
        if drag < -threshold, selected < loader.items.count - 1 {
            newIdx += 1
        } else if drag > threshold, selected > 0 {
            newIdx -= 1
        }
        // Update state immediately to avoid async issues
        for i in atDefaultStates.indices {
            atDefaultStates[i] = true
            progressStates[i] = 0
        }
        withAnimation(animation) {
            selected = newIdx
            dragOffset = 0
        }
        isDraggingHorizontally = false
        frozenExpansion = nil
        // Use a task to delay direction lock reset
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                directionLock = .undecided
            }
        }
    }
    
    /// Loads items from cache and initializes carousel state.
    private func loadItemsFromCache() {
        // Start data loading in background without blocking UI
        Task {
            await loader.loadInitialData(initialIndex: initialItemIndex)
            
            await MainActor.run {
                // Initialize arrays immediately when items are available
                if !loader.items.isEmpty {
                    let safeIndex = max(0, min(initialItemIndex, loader.items.count - 1))
                    if safeIndex != selected {
                        self.selected = safeIndex
                    }
                    
                    // Allow the selected panel to show content immediately
                    self.allowedToShowContent.insert(safeIndex)
                    
                    self.atDefaultStates = Array(repeating: true, count: loader.items.count)
                    self.progressStates = Array(repeating: 0.0, count: loader.items.count)
                    self.scrollOffsets = Array(repeating: 0.0, count: loader.items.count)
                }
                
                loadInitialCarouselData()
                // Load only the current panel immediately, adjacent will load with delay
                ensureVisiblePanelsHaveData(immediate: false)
            }
        }
    }
}