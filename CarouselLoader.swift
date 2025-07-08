import SwiftUI
import Foundation
import Combine

// MARK: - Generic Carousel Data Protocol

/// Protocol defining the requirements for data items used in a carousel
protocol CarouselDataItem {
    /// Unique identifier for the data item
    var id: String { get }
    /// Display name for the data item
    var displayName: String { get }
}

// MARK: - Carousel Loader Protocol

/// Generic protocol for loading and managing carousel data and views
/// Provides extensible interface for different data types (games, players, teams, etc.)
protocol CarouselLoader: ObservableObject {
    associatedtype DataItem: CarouselDataItem
    
    // MARK: - Data Management
    
    /// Array of data items to display in the carousel
    var items: [DataItem] { get }
    
    /// Flag indicating whether initial data loading is complete
    var isLoadingInitialData: Bool { get }
    
    /// Dictionary tracking data ready state for each item version
    var itemDataReady: [String: Bool] { get set }
    
    /// Dictionary tracking loading states for each item index
    var itemLoadingStates: [Int: Bool] { get set }
    
    // MARK: - Data Loading Methods
    
    /// Loads initial data for the carousel
    /// - Parameter initialIndex: The initial index to prioritize loading
    func loadInitialData(initialIndex: Int) async
    
    /// Loads data for a specific item with priority
    /// - Parameter index: The index of the item to load
    func loadItemWithPriority(at index: Int) async
    
    /// Loads data for a range of items concurrently
    /// - Parameter indices: Array of indices to load
    func loadItemRange(indices: [Int]) async
    
    /// Checks if all required data is loaded for a specific item
    /// - Parameter item: The data item to check
    /// - Returns: True if all data is available
    func isDataLoaded(for item: DataItem) -> Bool
    
    /// Checks if all data is ready for a specific item version with caching
    /// - Parameters:
    ///   - item: The data item to check
    ///   - version: The item version number
    /// - Returns: True if data is ready and cached
    func isAllDataReady(for item: DataItem, version: Int) -> Bool
    
    /// Loads historical or supplementary data for specific items
    /// - Parameter items: Array of data items to load supplementary data for
    func loadSupplementaryData(for items: [DataItem]) async
    
    // MARK: - View Creation Methods
    
    /// Creates a loading view for a specific item
    /// - Parameters:
    ///   - item: The data item to create loading view for
    ///   - message: Loading message to display
    /// - Returns: SwiftUI view showing loading state
    func createLoadingView(for item: DataItem, message: String) -> AnyView
    
    /// Creates the loaded content view for a specific item
    /// - Parameters:
    ///   - item: The data item to create view for
    ///   - index: The index of the item in the carousel
    ///   - version: The current version of the item
    ///   - versionRelay: Version relay for managing updates
    ///   - scrollStep: Binding to scroll step state
    /// - Returns: SwiftUI view with loaded content
    func createLoadedContentView(
        for item: DataItem,
        at index: Int,
        version: Int,
        versionRelay: PanelVersionRelay,
        scrollStep: Binding<Int>
    ) -> AnyView
    
    /// Gets the current content view for an item (loading or loaded)
    /// - Parameters:
    ///   - index: The index of the item
    ///   - item: The data item
    ///   - version: The current version
    ///   - versionRelay: Version relay for managing updates
    ///   - scrollStep: Binding to scroll step state
    /// - Returns: Current appropriate view for the item
    func getCurrentContentView(
        for index: Int,
        item: DataItem,
        version: Int,
        versionRelay: PanelVersionRelay,
        scrollStep: Binding<Int>
    ) -> AnyView
    
    // MARK: - Memory Management
    
    /// Cleans up all cached data and memory
    func cleanupMemory()
    
    /// Triggers full reload for category or data type switch
    func triggerFullReload()
}

// MARK: - Default Implementation

extension CarouselLoader {
    
    /// Default implementation for checking if data is ready with caching
    func isAllDataReady(for item: DataItem, version: Int) -> Bool {
        let itemKey = "\(item.id)_v\(version)"
        if let cachedReady = itemDataReady[itemKey] { return cachedReady }
        let isReady = isDataLoaded(for: item)
        // Cache the result without async dispatch to avoid state modification warnings
        if itemDataReady[itemKey] == nil {
            Task { @MainActor in
                self.itemDataReady[itemKey] = isReady
            }
        }
        return isReady
    }
    
    /// Default implementation for getting current content view
    func getCurrentContentView(
        for index: Int,
        item: DataItem,
        version: Int,
        versionRelay: PanelVersionRelay,
        scrollStep: Binding<Int>
    ) -> AnyView {
        if isAllDataReady(for: item, version: version) {
            return createLoadedContentView(
                for: item,
                at: index,
                version: version,
                versionRelay: versionRelay,
                scrollStep: scrollStep
            )
        } else {
            return createLoadingView(for: item, message: "Loading data...")
        }
    }
    
    /// Default implementation for loading item range concurrently
    func loadItemRange(indices: [Int]) async {
        await withTaskGroup(of: Void.self) { group in
            for index in indices {
                group.addTask {
                    await self.loadItemWithPriority(at: index)
                }
            }
        }
    }
    
    /// Default implementation for triggering full reload
    func triggerFullReload() {
        itemLoadingStates.removeAll()
        itemDataReady.removeAll()
    }
}

// MARK: - Carousel Configuration

/// Configuration struct for carousel behavior and appearance
struct CarouselConfiguration {
    /// Scroll thresholds for tracking item scroll progress
    let scrollThresholds: [CGFloat]
    /// Base gap between items when collapsed
    let baseGap: CGFloat
    /// Maximum gap between items when expanded
    let maxGap: CGFloat
    /// Amount to shrink inactive items
    let inactiveShrink: CGFloat
    /// Animation configuration for item transitions
    let animation: Animation
    /// Snap points for adaptive panel host
    let snapPoints: [CGFloat]
    /// Minimum width for panels
    let minWidth: CGFloat
    /// Maximum width for panels
    let maxWidth: CGFloat
    
    /// Default configuration for game panels
    static let gamePanel = CarouselConfiguration(
        scrollThresholds: [60, 90, 500],
        baseGap: 18,
        maxGap: 52,
        inactiveShrink: 28,
        animation: .interactiveSpring(response: 0.5, dampingFraction: 0.89),
        snapPoints: [
            UIScreen.main.bounds.height * 0.25,
            UIScreen.main.bounds.height * 0.85,
            UIScreen.main.bounds.height * 1.0
        ],
        minWidth: UIScreen.main.bounds.width * 0.91,
        maxWidth: UIScreen.main.bounds.width * 1.0
    )
    
    /// Default configuration for player panels
    static let playerPanel = CarouselConfiguration(
        scrollThresholds: [40, 70, 400],
        baseGap: 18,
        maxGap: 52,
        inactiveShrink: 28,
        animation: .interactiveSpring(response: 0.4, dampingFraction: 0.85),
        snapPoints: [
            UIScreen.main.bounds.height * 0.3,
            UIScreen.main.bounds.height * 0.8,
            UIScreen.main.bounds.height * 1.0
        ],
        minWidth: UIScreen.main.bounds.width * 0.91,
        maxWidth: UIScreen.main.bounds.width * 1.0
    )
    
    /// Default configuration for team panels
    static let teamPanel = CarouselConfiguration(
        scrollThresholds: [50, 80, 450],
        baseGap: 18,
        maxGap: 52,
        inactiveShrink: 28,
        animation: .interactiveSpring(response: 0.6, dampingFraction: 0.9),
        snapPoints: [
            UIScreen.main.bounds.height * 0.2,
            UIScreen.main.bounds.height * 0.9,
            UIScreen.main.bounds.height * 1.0
        ],
        minWidth: UIScreen.main.bounds.width * 0.91,
        maxWidth: UIScreen.main.bounds.width * 1.0
    )
}
