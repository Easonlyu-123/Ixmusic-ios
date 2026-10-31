import SwiftUI

@main
struct LuoxueMusicApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .preferredColorScheme(nil)
                .tint(Color.accentColor)
        }
    }
}
