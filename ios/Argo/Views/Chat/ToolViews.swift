// Adapted from nwverse/persona apple/Persona/Views/Chat/ToolViews.swift @ 3002eb3 (MIT).
import ArgoMobileKit
import BeautifulUI
import SwiftUI

/// Persona's BeautifulUI tool chip, with Argo's real call, output, diff and failure.
struct ToolCallRow: View {
    let item: ArgoChatItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ToolChipRow(BeautifulUI.ToolCall(id: item.id, .symbol(Theme.Icon.terminal),
                                           label: item.name.isEmpty ? L10n.text("Tool Result") : item.name,
                                           chip: item.call), isOpen: open) {
                open.toggle()
            }
            .tapTargetHeight()
            if item.failed {
                Label("Tool failed", systemImage: Theme.Icon.warning)
                    .font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
            if open {
                if !item.call.isEmpty {
                    Text(verbatim: item.call)
                        .font(Theme.Font.code).foregroundStyle(.secondary)
                        .readingContent().textSelection(.enabled)
                }
                if !item.text.isEmpty {
                    ReplyCodeBlock(text: item.text, language: L10n.text(item.type == "tool" ? "Input" : "Output"))
                }
                if !item.diff.isEmpty { ReplyCodeBlock(text: item.diff, language: "diff") }
                if !item.output.isEmpty && item.output != item.text { ReplyCodeBlock(text: item.output, language: L10n.text("Output")) }
                if let exit = item.exit { Text("Exit code: \(exit)").font(Theme.Font.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatProgressView: View {
    let team: ArgoTeamView?
    let managed: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let team {
                    if let plan = team.plan, !plan.items.isEmpty {
                        Section("Plan · \(plan.done)/\(plan.total)") {
                            ForEach(Array(plan.items.enumerated()), id: \.offset) { _, item in
                                Label {
                                    Text(verbatim: item.text).readingContent()
                                } icon: {
                                    Image(systemName: item.isDone ? "checkmark.circle.fill" : item.isActive ? "circle.dotted" : "circle")
                                        .foregroundStyle(item.isDone ? Theme.positive : item.isActive ? Theme.busy : .secondary)
                                }
                            }
                        }
                    }
                    if !team.tasks.isEmpty {
                        Section("Team Tasks") {
                            ForEach(team.tasks) { task in
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(verbatim: task.title).font(Theme.Font.bodyStrong).readingContent()
                                    Text(verbatim: [task.owner, task.status].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                                    if !task.description.isEmpty { Text(verbatim: task.description).font(Theme.Font.secondary).readingContent() }
                                }
                            }
                        }
                    }
                    Section("Recent Activity") {
                        ForEach(Array(team.steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: Theme.Space.m) {
                                Image(systemName: step.mark == "fail" ? Theme.Icon.warning : Theme.Icon.terminal)
                                    .foregroundStyle(step.mark == "fail" ? Theme.danger : .secondary)
                                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                    Text(verbatim: step.text).font(Theme.Font.secondary).readingContent().textSelection(.enabled)
                                    HStack {
                                        if step.count > 1 { Text("\(step.count) actions") }
                                        MessageTime(at: step.at)
                                    }
                                    .font(Theme.Font.label).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if team.steps.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                    }
                    if !team.error.isEmpty { Section { NoticeBanner(text: team.error, tone: .danger, lineLimit: nil) } }
                } else {
                    Text(L10n.text(managed
                        ? "Progress hasn't loaded yet. Return to the conversation and refresh."
                        : "This session wasn't started by Argo. You can view its native conversation, but managed Agent progress isn't available."))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Agent Progress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
