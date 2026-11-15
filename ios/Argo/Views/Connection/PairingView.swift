import SwiftUI
import UIKit

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Text("Connect your computer").font(Theme.Font.title)
                        Text("Run argo pair on your computer, then paste the pairing code here.")
                            .foregroundStyle(.secondary)
                            .readingContent()
                    }
                    .padding(.vertical, Theme.Space.s)
                }
                Section {
                    TextField("argo1:…", text: $code, axis: .vertical)
                        .lineLimit(3...6)
                        .font(Theme.Font.code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($codeFocused)
                        .privacySensitive()
                        .accessibilityLabel("Pairing Code")
                        .accessibilityIdentifier("pairing-code")
                    PasteButton(payloadType: String.self) { values in
                        if let pasted = values.first { code = pasted }
                    }
                    .accessibilityLabel("Paste Pairing Code")
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("The code is used once. Device credentials are stored in this device's Keychain.")
                }
                Section("Host Name") {
                    TextField("Optional name", text: $name)
                        .textContentType(.nickname)
                        .accessibilityIdentifier("host-name")
                }
                if let problem = model.pairingProblem {
                    Section {
                        NoticeBanner(text: problem, tone: .danger, lineLimit: nil)
                            .accessibilityIdentifier("pairing-error")
                    }
                }
                Section {
                    Button {
                        codeFocused = false
                        model.pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                                   name: name, deviceName: UIDevice.current.name)
                    } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if model.pairing { ProgressView() }
                            else { Image(systemName: Theme.Icon.connection) }
                        }
                        .tapTargetHeight()
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pairing)
                    .accessibilityIdentifier("pair-host-submit")
                }
            }
            .disabled(model.pairing)
            .navigationTitle("Connect a Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelPairing(); dismiss() }
                }
            }
            .onChange(of: model.pairedHostID) { _, id in
                if id != nil { code = ""; dismiss() }
            }
            .onDisappear { code = ""; model.cancelPairing() }
        }
        .interactiveDismissDisabled(model.pairing)
    }
}
