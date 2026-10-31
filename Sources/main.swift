import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "hook":
    exit(AgentHook.run(arguments: Array(arguments.dropFirst())))
case "guard":
    LidGuard.runChild()
    exit(0)
case "connect", "disconnect":
    exit(AgentIntegration.runCommand(arguments))
default:
    break
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
