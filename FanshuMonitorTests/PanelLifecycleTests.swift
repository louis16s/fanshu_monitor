import Foundation
import Testing
@testable import FanshuMonitor

@MainActor
struct PanelExpansionStateTests {
    @Test func defaultsToExpandedAndPersistsCollapsedSections() {
        let suite = "PanelExpansionStateTests.defaultsToExpandedAndPersistsCollapsedSections"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let state = PanelExpansionState(defaults: defaults)
        #expect(state.isExpanded(.module(.cpu)))
        #expect(state.isExpanded(.display))

        state.setExpanded(false, for: .module(.cpu))
        state.setExpanded(false, for: .display)

        let restored = PanelExpansionState(defaults: defaults)
        #expect(!restored.isExpanded(.module(.cpu)))
        #expect(!restored.isExpanded(.display))
        #expect(restored.isExpanded(.module(.gpu)))

        restored.toggle(.display)
        #expect(PanelExpansionState(defaults: defaults).isExpanded(.display))
    }

    @Test func ignoresUnknownStoredSectionIdentifiers() {
        let suite = "PanelExpansionStateTests.ignoresUnknownStoredSectionIdentifiers"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["module.cpu", "removed-module"], forKey: "panel.collapsedSections.v1")

        let state = PanelExpansionState(defaults: defaults)

        #expect(!state.isExpanded(.module(.cpu)))
        #expect(state.collapsedStorageIDs == ["module.cpu"])
    }
}

struct DisplayControlDemandPolicyTests {
    @Test func closedPanelDoesNotLoadDisplayControlsWithoutAnExplicitFeatureDemand() {
        let demand = demand(panelVisible: false, sectionExpanded: true)

        #expect(!demand.controllerRequired)
        #expect(demand.activeControls.isEmpty)
        #expect(!demand.capabilitiesRequested)
    }

    @Test func collapsedDisplaySectionKeepsOnlyLightweightTopologyDiscovery() {
        let demand = demand(panelVisible: true, sectionExpanded: false)

        #expect(demand.controllerRequired)
        #expect(demand.activeControls.isEmpty)
        #expect(!demand.capabilitiesRequested)
    }

    @Test func expandedDisplaySectionLoadsOnlyEnabledControls() {
        let demand = demand(
            panelVisible: true,
            sectionExpanded: true,
            brightnessEnabled: true,
            volumeEnabled: false,
            contrastEnabled: true,
            capabilitiesEnabled: true
        )

        #expect(demand.activeControls == [.brightness, .contrast])
        #expect(demand.capabilitiesRequested)
    }

    @Test func brightnessKeyInterceptionKeepsOnlyBrightnessReadyInTheBackground() {
        let demand = demand(
            panelVisible: false,
            sectionExpanded: false,
            brightnessEnabled: true,
            volumeEnabled: true,
            contrastEnabled: true,
            capabilitiesEnabled: true,
            interceptBrightnessKeys: true
        )

        #expect(demand.controllerRequired)
        #expect(demand.activeControls == [.brightness])
        #expect(!demand.capabilitiesRequested)
    }

    private func demand(
        panelVisible: Bool,
        sectionExpanded: Bool,
        brightnessEnabled: Bool = true,
        volumeEnabled: Bool = true,
        contrastEnabled: Bool = true,
        capabilitiesEnabled: Bool = true,
        interceptBrightnessKeys: Bool = false
    ) -> DisplayControlDemand {
        DisplayControlDemandPolicy.resolve(
            panelVisible: panelVisible,
            displaySectionExpanded: sectionExpanded,
            displayModuleVisible: true,
            brightnessControlEnabled: brightnessEnabled,
            volumeControlEnabled: volumeEnabled,
            contrastControlEnabled: contrastEnabled,
            capabilitiesEnabled: capabilitiesEnabled,
            brightnessKeyInterceptionEnabled: interceptBrightnessKeys,
            needsBuiltInBlackoutMaintenance: false
        )
    }
}
