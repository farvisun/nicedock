import AppKit
import SwiftUI

/// "AI Assistant" section of Privacy & Permissions: the two safety switches for `NiceDock --mcp` and
/// ready-to-paste setup for MCP clients.
struct AIAssistantGroup: View {
    static let anchor = "aiAssistant"
    private var store: AppStore { .shared }

    var body: some View {
        let s = store.settings
        SettingsGroup(title: L("AI Assistant"),
                      footer: L("Claude, Codex, Cursor, VS Code and other MCP clients can read and configure NiceDock, from dock style to widget settings, and paint a wallpaper by mood, season or weather. API tokens and other secrets are never shared.")) {
            ToggleRow(title: L("Enable AI Assistant"), subtitle: L("Lets assistants on this Mac read your Dock setup through NiceDock's MCP server."),
                      isOn: setting(\.assistantEnabled))
            ToggleRow(title: L("Allow Changes"),
                      subtitle: s.assistantEnabled
                          ? L("Off: assistants can only read. On: they can change the Dock, widgets, profiles and the wallpaper.")
                          : L("Turn on Enable AI Assistant first."),
                      isOn: setting(\.assistantAllowsChanges))
                .disabled(!s.assistantEnabled)
            SettingsRow(title: L("Access")) { AssistantStatusBadge(enabled: s.assistantEnabled, changes: s.assistantAllowsChanges) }
        }
        .id(Self.anchor)

        SettingsGroup(title: L("Connect an Assistant"),
                      footer: L("Paste the setup into your assistant, then start a new session. The assistant starts NiceDock's MCP server itself; no network port is opened.")) {
            if AssistantSetup.isTranslocated {
                Label(L("Move NiceDock to the Applications folder first: macOS is running it from a temporary location."), systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(11.5)).foregroundStyle(Color.cdOrange).fixedSize(horizontal: false, vertical: true)
            }
            SetupSnippetRow(product: "Claude Code", detail: L("Run in Terminal:"), snippet: AssistantSetup.claudeCode)
            SetupSnippetRow(product: "Codex", detail: L("Add to %@:", "~/.codex/config.toml"), snippet: AssistantSetup.codex)
            SetupSnippetRow(product: "Cursor", detail: L("Add to %@:", "~/.cursor/mcp.json"), snippet: AssistantSetup.cursor)
            SetupSnippetRow(product: "VS Code", detail: L("Add to %@ in your workspace:", ".vscode/mcp.json"), snippet: AssistantSetup.vscode)
            SetupSnippetRow(product: L("Other MCP clients"), detail: L("Command and argument:"), snippet: AssistantSetup.command)
        }
    }
}

private struct AssistantStatusBadge: View {
    var enabled: Bool
    var changes: Bool

    var body: some View {
        let (text, symbol, tint): (String, String, Color) = !enabled
            ? (L("Off"), "power", .secondary)
            : changes ? (L("Can make changes"), "pencil.circle.fill", .cdOrange) : (L("Read-only"), "eye.circle.fill", .cdGreen)
        Label(text, systemImage: symbol).font(.ui(11.5, .medium)).foregroundStyle(tint)
    }
}

/// Client name, where the snippet goes, the snippet itself (always left-to-right) and a Copy button.
private struct SetupSnippetRow: View {
    let product: String
    let detail: String
    let snippet: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(product).font(.ui(13, .medium))
                Text(detail).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                } label: {
                    Label(copied ? L("Copied") : L("Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            Text(verbatim: snippet)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// Setup snippets with the path of the running NiceDock binary.
enum AssistantSetup {
    /// Snapshot tests show the installed path instead of the test runner's.
    nonisolated(unsafe) static var pathOverride: String?

    static var executablePath: String {
        pathOverride ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "/Applications/NiceDock.app/Contents/MacOS/NiceDock"
    }

    /// Gatekeeper path randomization: the path changes on every launch until the app is moved.
    static var isTranslocated: Bool { executablePath.contains("/AppTranslocation/") }

    static func shellQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    static func jsonQuoted(_ s: String) -> String { JSONValue.string(s).text() }

    static func snippets(path: String) -> (claudeCode: String, codex: String, cursor: String, vscode: String, command: String) {
        let json = jsonQuoted(path)
        return (
            "claude mcp add nicedock -- \(shellQuoted(path)) --mcp",
            "[mcp_servers.nicedock]\ncommand = \(json)\nargs = [\"--mcp\"]",
            "{\n  \"mcpServers\": {\n    \"nicedock\": {\n      \"command\": \(json),\n      \"args\": [\"--mcp\"]\n    }\n  }\n}",
            "{\n  \"servers\": {\n    \"nicedock\": {\n      \"type\": \"stdio\",\n      \"command\": \(json),\n      \"args\": [\"--mcp\"]\n    }\n  }\n}",
            "\(shellQuoted(path)) --mcp"
        )
    }

    static var claudeCode: String { snippets(path: executablePath).claudeCode }
    static var codex: String { snippets(path: executablePath).codex }
    static var cursor: String { snippets(path: executablePath).cursor }
    static var vscode: String { snippets(path: executablePath).vscode }
    static var command: String { snippets(path: executablePath).command }
}
