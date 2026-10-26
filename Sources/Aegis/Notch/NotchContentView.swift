import SwiftUI

struct NotchContentView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        CollapsedNotchView(sessionStore: sessionStore)
            .background(NotchShape(cornerRadius: 17).fill(.black))
            .clipShape(NotchShape(cornerRadius: 14))
            .environment(\.notchTheme, settingsStore.notchThemeID.theme)
    }
}
