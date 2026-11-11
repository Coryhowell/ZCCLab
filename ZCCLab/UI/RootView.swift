import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard, tools, environment, scenarios, timeline, logs, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .tools: "wrench.and.screwdriver"
        case .environment: "network"
        case .scenarios: "camera.viewfinder"
        case .timeline: "chart.xyaxis.line"
        case .logs: "terminal"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    #if os(macOS)
    @State private var selection: AppTab? = .dashboard
    #else
    @State private var selection: AppTab = .dashboard
    #endif

    @ViewBuilder private func screen(_ tab: AppTab) -> some View {
        switch tab {
        case .dashboard: DashboardView()
        case .tools: ToolsView()
        case .environment: EnvironmentView()
        case .scenarios: ScenariosView()
        case .timeline: TimelineView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(AppTab.allCases, selection: $selection) { tab in
                Label(tab.title, systemImage: tab.icon).tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            NavigationStack { screen(selection ?? .dashboard) }
        }
        .frame(minWidth: 960, minHeight: 640)
        #else
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack { screen(tab) }
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .tag(tab)
            }
        }
        #endif
    }
}

// MARK: - Cross-platform helpers

enum Clipboard {
    @MainActor static func copy(_ s: String) {
        #if os(iOS)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
        zlog(.ui, .debug, "Copied \(s.count) characters to clipboard")
    }
}

extension View {
    /// Plain text field behavior for hostnames / URLs on both platforms.
    func plainInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    func inlineTitle(_ title: String) -> some View {
        #if os(iOS)
        self.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        #else
        self.navigationTitle(title)
        #endif
    }
}

struct Mono: ViewModifier {
    var size: CGFloat = 12
    func body(content: Content) -> some View {
        content.font(.system(size: size, design: .monospaced)).textSelection(.enabled)
    }
}
extension View { func mono(_ size: CGFloat = 12) -> some View { modifier(Mono(size: size)) } }

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}
