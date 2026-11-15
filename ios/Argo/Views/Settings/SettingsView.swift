// Adapted from nwverse/persona apple/Persona/Views/Settings/SettingsView.swift @ 3002eb3 (MIT).
// Retains the system-label rows and device/connection grouping for Argo's local settings.
import SwiftUI

nonisolated enum AppAppearance: String {
    case system, light, dark

    static let storageKey = "argo.appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @Environment(\.dismiss) private var dismiss
    @State private var hostsShown = false
    @State private var hostPairingShown = false

    var body: some View {
        NavigationStack {
            List {
                Section("This Device") {
                    Picker(selection: $appearance) {
                        Text("Follow System").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("settings-appearance")
                }
                Section("Connection") {
                    Button { hostsShown = true } label: {
                        Label("Hosts and Workspaces", systemImage: Theme.Icon.connection)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings-hosts-workspaces")
                }
                Section("About") {
                    LabeledContent("Version") {
                        Text(verbatim: appVersion).textSelection(.enabled)
                    }
                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        Label("Third-Party Licenses", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("settings-licenses")
                }
            }
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("settings-list")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .readingContent()
        .sheet(isPresented: $hostsShown) { HostWorkspaceView(pairingShown: $hostPairingShown) }
    }

    private var appVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return L10n.text("Unavailable")
        }
        return "\(version) (\(build))"
    }
}

private struct ThirdPartyLicensesView: View {
    var body: some View {
        List {
            NavigationLink {
                LicenseTextView(title: "Persona", resource: "Persona-LICENSE")
            } label: { Text(verbatim: "Persona") }
            NavigationLink {
                LicenseTextView(title: "BeautifulUI", resource: "BeautifulUI-LICENSE")
            } label: { Text(verbatim: "BeautifulUI") }
            NavigationLink {
                LicenseTextView(title: "Beautiful UI", resource: "BeautifulUI-LICENSE-beautifului")
            } label: { Text(verbatim: "Beautiful UI") }
            NavigationLink {
                LicenseTextView(title: L10n.text("BeautifulUI Notice"), resource: "BeautifulUI-NOTICE")
            } label: { Text("BeautifulUI Notice") }
        }
        .navigationTitle("Third-Party Licenses")
    }
}

private struct LicenseTextView: View {
    let title: String
    let resource: String
    @State private var text: String?
    @State private var problem: String?

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Text(verbatim: text)
                        .font(Theme.Font.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.l)
                }
            } else if let problem {
                ContentUnavailableView("License Unavailable", systemImage: "doc.text",
                                       description: Text(verbatim: problem))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: title))
        .task {
            do {
                guard let url = Bundle.main.url(forResource: resource, withExtension: "txt") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                text = try String(contentsOf: url, encoding: .utf8)
            } catch { problem = error.localizedDescription }
        }
    }
}
