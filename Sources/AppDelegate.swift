import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keeper: Keeper!
    private var statusMenu: StatusMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Settings.register()
        SleepSwitch.restoreAfterCrash()
        LidGuard.launch()
        keeper = Keeper()
        statusMenu = StatusMenu(keeper: keeper)
        keeper.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        keeper.shutdown()
    }
}
