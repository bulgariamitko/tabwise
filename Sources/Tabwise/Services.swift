import AppKit

/// Finder's right-click menu on a folder (Quick Actions / Services): "New Tabwise Session Here" and
/// "Continue Tabwise Session Here". The items are declared under NSServices in Info.plist (see build.sh).
@MainActor
final class FinderServices: NSObject {
    private static var provider: FinderServices?
    private let store: DeckStore

    private init(store: DeckStore) { self.store = store }

    static func register(_ store: DeckStore) {
        let provider = FinderServices(store: store)
        Self.provider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    @objc func newSession(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pboard, continueLast: false)
    }

    @objc func continueSession(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pboard, continueLast: true)
    }

    /// One tab per selected folder, with the agent last picked in New Session (Claude unless you changed it).
    private func open(_ pboard: NSPasteboard, continueLast: Bool) {
        let folders = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.path)
        guard !folders.isEmpty else { NSSound.beep(); return }
        store.whenLaunched { [store] in
            for folder in folders {
                AppActions.lastFolder = folder
                store.newAgent(AppActions.lastAgent, in: folder, continueLatest: continueLast)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
