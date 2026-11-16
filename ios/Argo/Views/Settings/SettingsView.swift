// Adapted from nwverse/persona apple/Persona/Views/Settings/SettingsView.swift @ 3002eb3 (MIT).
// Retains the system-label rows and device/connection grouping for Argo's local settings.
import SwiftUI
import UIKit
import UserNotifications

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
    @AppStorage(ReturnSends.enabledKey) private var returnSends = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var hostsPresentation = SeenPresentation()
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
                    Toggle(isOn: $returnSends) {
                        Label("Return Key Sends", systemImage: "arrow.turn.down.left")
                    }
                    .accessibilityHint(Text("Send with Return; Shift-Return starts a new line"))
                    .accessibilityIdentifier("settings-return-sends")
                }
                Section("Connection") {
                    Button { hostsPresentation.setPresented(true, in: model) } label: {
                        Label("Hosts and Workspaces", systemImage: Theme.Icon.connection)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("settings-hosts-workspaces")
                }
                Section("Notifications") {
                    if let host = model.selectedHost {
                        Toggle("Agent Alerts on This Device", isOn: Binding(
                            get: { PhoneNotifications.shared.enabledHosts.contains(host.id) },
                            set: { value in Task { await PhoneNotifications.shared.setEnabled(value, host: host) } }))
                            .disabled(PhoneNotifications.shared.busy)
                            .accessibilityIdentifier("settings-phone-notifications")
                        Text("Alerts from the selected host contain status only. Tap an alert to open its Agent.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Pair a host to enable Agent alerts.").foregroundStyle(.secondary)
                    }
                    if let problem = PhoneNotifications.shared.problem(for: model.selectedHost?.id) {
                        Text(verbatim: problem).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry Notifications") { Task { await PhoneNotifications.shared.refresh() } }
                    }
                    if PhoneNotifications.shared.authorization == .denied {
                        Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    }
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
        .sheet(isPresented: hostsPresentation.binding(in: model),
               onDismiss: { hostsPresentation.didDismiss(in: model) }) {
            HostWorkspaceView(pairingShown: $hostPairingShown, pairingDismissed: {})
        }
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
