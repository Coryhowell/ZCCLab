import SwiftUI

@main
struct ZCCLabApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .task { SignalEngine.shared.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            SignalEngine.shared.scenePhaseChanged(phase)
        }
    }
}
