import AppKit
import SwiftUI

extension Notification.Name {
    static let macCLIShowMainWindow = Notification.Name("macCLIShowMainWindow")
}

@main
struct MacCLIProxyAPIApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // `Window` = single instance (unlike WindowGroup which spawns duplicates).
        Window("MacCLIProxyAPI", id: "main") {
            ContentView()
                .environment(appState)
                .preferredColorScheme(appState.preferredColorScheme)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    // Main window is open → show Dock icon.
                    NSApp.setActivationPolicy(.regular)
                }
                .onReceive(NotificationCenter.default.publisher(for: .macCLIShowMainWindow)) { note in
                    if let page = note.object as? AppPage {
                        appState.select(page)
                    } else if note.object == nil {
                        // Explicit "open home" when object is nil and user asked for main UI.
                        // Keep current page if only re-fronting without page change —
                        // MenuBar passes AppPage.home for 主界面.
                    }
                    AppDelegate.showMainWindow()
                }
        }
        .defaultSize(width: 1280, height: 840)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarPanelView()
                .environment(appState)
                .preferredColorScheme(appState.preferredColorScheme)
        } label: {
            MenuBarLabelView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Status item: custom orbital-capacity mark + selected source remaining %.
private struct MenuBarLabelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Touch observed fields so label refreshes when quotas / selection change.
        let _ = appState.selectedMenuBarQuotaAccountID
        let _ = appState.coreStatus.running
        let percent = appState.menuBarRemainingPercent
        HStack(spacing: 5) {
            MenuBarStatusIcon(remainingPercent: percent, kind: iconKind(percent: percent))
            Text(appState.menuBarTitle)
                .monospacedDigit()
        }
        .help(helpText(percent: percent))
    }

    private func iconKind(percent: Double?) -> MenuBarStatusIcon.Kind {
        if !appState.coreStatus.installed || !appState.coreStatus.running {
            return .idle
        }
        if percent != nil {
            return .provider
        }
        return .live
    }

    private func helpText(percent: Double?) -> String {
        var parts = ["MacCLIProxyAPI · \(appState.coreStatus.message)"]
        if let account = appState.selectedMenuBarQuotaAccount {
            parts.append(account.displayName)
            if let percent {
                parts.append(String(format: "剩余 %.0f%%", percent))
            } else if let text = account.primaryDisplayText {
                parts.append(text)
            }
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowCloseObserver: NSObjectProtocol?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep menu-bar agent alive after the main window is closed.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock icon click / reopen → show main UI again.
        Self.presentMainWindow(openIfNeeded: true)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Observe main window close so we can leave Dock and stay menu-bar only.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleWindowWillClose(note)
            }
        }

        // After first layout, if no main window is visible, prefer accessory (menu-bar only).
        DispatchQueue.main.async {
            Self.updateActivationPolicyForMainWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        // Always stop the managed/orphaned core so ports (e.g. 28317) are released.
        AppState.shared?.shutdownCoreOnAppExit()
    }

    private func handleWindowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow else { return }
        // Defer until the window is removed from NSApp.windows.
        DispatchQueue.main.async {
            let remaining = Self.mainWindows().filter { $0 !== closing }
            if remaining.isEmpty {
                // Menu-bar only: no Dock icon.
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Main titled windows that belong to the app UI (exclude menu-bar panels).
    static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.styleMask.contains(.titled) else { return false }
            if window.isSheet { return false }
            if window.level.rawValue >= NSWindow.Level.statusBar.rawValue { return false }
            let className = String(describing: type(of: window))
            if className.localizedCaseInsensitiveContains("menubar")
                || className.localizedCaseInsensitiveContains("statusitem")
                || className.localizedCaseInsensitiveContains("NSStatus")
                || className.localizedCaseInsensitiveContains("MenuBarExtra")
            {
                return false
            }
            // MenuBarExtra panel windows are usually borderless or non-main.
            if !window.canBecomeMain && !window.canBecomeKey { return false }
            return true
        }
    }

    static func hasMainWindow() -> Bool {
        !mainWindows().isEmpty
    }

    static func updateActivationPolicyForMainWindows() {
        if mainWindows().contains(where: { $0.isVisible || $0.isMiniaturized }) {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Front existing main window. Returns false if none exists yet.
    @discardableResult
    static func showMainWindow() -> Bool {
        // Restore Dock presence while the main UI is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        let windows = mainWindows()
        guard let window = windows.first(where: { $0.title.contains("MacCLIProxyAPI") })
                ?? windows.first
        else {
            return false
        }

        // Close accidental duplicates — keep the first main window only.
        for extra in windows.dropFirst() {
            extra.close()
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    /// Present main window: front if exists. Caller may openWindow when this returns false.
    static func presentMainWindow(openIfNeeded: Bool) {
        // Polling backs off while menu-bar only, so the reopened window would otherwise show
        // whatever the last background sample found.
        AppState.shared?.refreshOnForeground()
        if showMainWindow() { return }
        if openIfNeeded {
            NSApp.setActivationPolicy(.regular)
            // Last resort: post notification handled after SwiftUI opens window.
            NotificationCenter.default.post(name: .macCLIShowMainWindow, object: nil)
        }
    }
}
