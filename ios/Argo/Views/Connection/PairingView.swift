// Adapted from nwverse/persona apple/Persona/Views/Settings/SettingsView.swift
// PairView @ 89927b54baab6b8207315f6c2a4d2e5831598d45 (MIT).
import AVFoundation
import SwiftUI
import UIKit
import VisionKit

struct PairingView: View {
    private enum Camera { case checking, ready, denied, unavailable }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var name = ""
    @State private var camera = Camera.checking
    @State private var scanRequested = true
    @State private var manual = false
    @State private var visible = false
    @FocusState private var codeFocused: Bool

    private var showingScanner: Bool {
        visible && scenePhase == .active && camera == .ready && scanRequested && !manual && !model.pairing
    }

    private var canConnect: Bool {
        visible && scenePhase == .active && manual && !model.pairing &&
            !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        Text("Connect your computer").font(Theme.Font.title)
                        Text("Run argo pair on your computer, then scan or paste the pairing code.")
                            .foregroundStyle(.secondary)
                            .readingContent()
                    }
                    .padding(.vertical, Theme.Space.s)
                }
                if !manual {
                    Section {
                        if showingScanner {
                            PairingScanner { payload in
                                guard showingScanner else { return }
                                scanRequested = false
                                code = payload
                                manual = true
                                connect()
                            } onUnavailable: {
                                guard showingScanner else { return }
                                scanRequested = false
                                camera = .unavailable
                            }
                            .scaledFrame(height: 280)
                            .clipShape(.rect(cornerRadius: Theme.Radius.card, style: .continuous))
                            .listRowInsets(EdgeInsets())
                            .accessibilityLabel("Pairing code scanner")
                        } else if camera == .checking {
                            ProgressView().accessibilityLabel("Checking camera access")
                        } else if camera == .denied {
                            Text("Camera access is off. Paste a pairing code or enter it manually.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("pairing-camera-denied")
                        } else if camera == .unavailable {
                            Text("QR scanning is unavailable on this device. Paste a pairing code or enter it manually.")
                                .foregroundStyle(.secondary)
                        } else {
                            Button(action: beginScanning) {
                                Label("Scan Pairing Code", systemImage: "qrcode.viewfinder").tapTargetHeight()
                            }
                            .disabled(model.pairing)
                            .accessibilityIdentifier("pairing-scan")
                        }
                    } footer: {
                        Text("Scan the QR code printed by argo pair. The code is valid once and expires after 10 minutes.")
                    }
                }
                Section {
                    PasteButton(payloadType: String.self) { values in
                        guard visible, scenePhase == .active, !model.pairing, let pasted = values.first else { return }
                        scanRequested = false
                        code = pasted
                        manual = true
                    }
                    .accessibilityLabel("Paste Pairing Code")
                    .disabled(model.pairing)
                    if manual {
                        Button(action: beginScanning) {
                            Label("Scan Pairing Code", systemImage: "qrcode.viewfinder").tapTargetHeight()
                        }
                        .disabled(model.pairing)
                    } else {
                        Button {
                            scanRequested = false
                            manual = true
                            codeFocused = true
                        } label: {
                            Label("Enter Manually", systemImage: "keyboard").tapTargetHeight()
                        }
                        .disabled(model.pairing)
                        .accessibilityIdentifier("pairing-manual")
                    }
                }
                if manual {
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
                    } header: {
                        Text("Pairing Code")
                    } footer: {
                        Text("Enter the complete argo1: code, including the address, certificate fingerprint and one-time secret.")
                    }
                    .disabled(model.pairing)
                }
                Section("Host Name") {
                    TextField("Optional name", text: $name)
                        .textContentType(.nickname)
                        .accessibilityIdentifier("host-name")
                }
                .disabled(model.pairing)
                if let problem = model.pairingProblem {
                    Section {
                        NoticeBanner(text: problem, tone: .danger, lineLimit: nil)
                            .accessibilityIdentifier("pairing-error")
                    }
                }
                Section {
                    Text(verbatim: "argo pair").font(Theme.Font.code).textSelection(.enabled)
                } header: {
                    Text("Command line")
                } footer: {
                    Text("The code is used once. Device credentials are stored in this device's Keychain.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground)
            .navigationTitle("Connect a Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: connect) {
                        if model.pairing { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(!canConnect)
                    .accessibilityIdentifier("pair-host-submit")
                }
            }
            .onAppear { visible = true }
            .task(id: scenePhase) { await prepareScanner() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { scanRequested = false; model.cancelPairing() }
            }
            .onChange(of: model.pairedHostID) { _, id in
                if visible, scenePhase == .active, id != nil { stop(); dismiss() }
            }
            .onDisappear { stop() }
        }
        .accessibilityHidden(scenePhase != .active)
        .overlay {
            if scenePhase != .active {
                Theme.pageBackground.ignoresSafeArea()
                    .overlay {
                        Image("ArgoMark").resizable().scaledToFit()
                            .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                    }
                    .accessibilityHidden(true)
                    .transition(.identity)
            }
        }
    }

    private func beginScanning() {
        guard visible, scenePhase == .active, !model.pairing else { return }
        codeFocused = false
        code = ""
        manual = false
        scanRequested = true
    }

    private func connect() {
        guard canConnect else { return }
        codeFocused = false
        scanRequested = false
        model.pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                   name: name, deviceName: UIDevice.current.name)
    }

    private func stop() {
        visible = false
        scanRequested = false
        code = ""
        model.cancelPairing()
    }

    private func prepareScanner() async {
        guard visible, scenePhase == .active else { return }
        guard DataScannerViewController.isSupported else { camera = .unavailable; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: allowed = false
        @unknown default: allowed = false
        }
        guard !Task.isCancelled, visible, scenePhase == .active else { return }
        camera = allowed ? (DataScannerViewController.isAvailable ? .ready : .unavailable) : .denied
    }
}
