import AppKit

MainActor.assumeIsolated {
    let argv = CommandLine.arguments
    if CLI.isCommand(argv) {
        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task.detached { code = await CLI.run(argv); done.signal() }
        while done.wait(timeout: .now() + 0.01) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        exit(code)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
