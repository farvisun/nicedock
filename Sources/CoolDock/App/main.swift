import AppKit

// `NiceDock --mcp`: stdio MCP server for AI assistants. Runs before NSApplication is created: no UI, no prompts.
if CommandLine.arguments.contains("--mcp") {
    MCPServer.runStdio()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    #if DEBUG
    if MenuProbe.runIfRequested() { app.run() }
    UIProbe.prepareIfRequested()
    #endif
    if RenderHarness.runIfRequested() {
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
