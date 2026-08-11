//
//  ContentView.swift
//  FanshuMonitor
//
//  
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var settings: MonitorSettings

    var body: some View {
        MonitorPanelView(store: store, settings: settings)
            .padding(18)
    }
}
