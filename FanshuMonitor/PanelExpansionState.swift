import Combine
import Foundation

enum PanelSectionID: Hashable, Sendable {
    case module(MonitorKind)
    case display

    fileprivate var storageID: String {
        switch self {
        case .module(let kind):
            return "module.\(kind.rawValue)"
        case .display:
            return "display"
        }
    }

    fileprivate static let validStorageIDs = Set(
        MonitorKind.allCases.map { "module.\($0.rawValue)" } + ["display"]
    )
}

@MainActor
final class PanelExpansionState: ObservableObject {
    private static let collapsedSectionsKey = "panel.collapsedSections.v1"

    @Published private(set) var collapsedStorageIDs: Set<String>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedIDs = defaults.stringArray(forKey: Self.collapsedSectionsKey) ?? []
        collapsedStorageIDs = Set(storedIDs).intersection(PanelSectionID.validStorageIDs)
    }

    func isExpanded(_ section: PanelSectionID) -> Bool {
        !collapsedStorageIDs.contains(section.storageID)
    }

    func setExpanded(_ expanded: Bool, for section: PanelSectionID) {
        var updatedIDs = collapsedStorageIDs
        if expanded {
            updatedIDs.remove(section.storageID)
        } else {
            updatedIDs.insert(section.storageID)
        }
        guard updatedIDs != collapsedStorageIDs else { return }
        collapsedStorageIDs = updatedIDs
        defaults.set(updatedIDs.sorted(), forKey: Self.collapsedSectionsKey)
    }

    func toggle(_ section: PanelSectionID) {
        setExpanded(!isExpanded(section), for: section)
    }
}
