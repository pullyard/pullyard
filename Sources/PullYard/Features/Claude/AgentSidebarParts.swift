import AppKit
import SwiftUI

struct AgentRowBackground: View {
    let selected: Bool
    var focused = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.syText.opacity(0.1) : (focused ? Color.syText.opacity(0.06) : Color.clear))
            .overlay {
                if focused && !selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.syLineStrong)
                }
            }
            .padding(.horizontal, 4)
    }
}

struct AgentSectionHeader<Accessory: View>: View {
    let title: String
    var collapsed: Binding<Bool>? = nil
    var count: Int? = nil
    @ViewBuilder var accessory: Accessory
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.syCaption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(hover && collapsed != nil ? Color.syMuted : Color.syDim)
                if let collapsed {
                    if collapsed.wrappedValue, let count {
                        Text(verbatim: "\(count)")
                            .font(.syCaption2.monospacedDigit())
                            .foregroundStyle(Color.syDim)
                    }
                    Image(systemName: "chevron.right")
                        .font(.syCaption2.weight(.bold))
                        .foregroundStyle(Color.syDim)
                        .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                        .opacity(hover || collapsed.wrappedValue ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let collapsed else { return }
                withAnimation(Motion.smooth) { collapsed.wrappedValue.toggle() }
            }
            .accessibilityAddTraits(collapsed == nil ? [] : .isButton)
            .accessibilityHint(collapsed == nil ? "" : (collapsed!.wrappedValue ? "Show" : "Hide"))
            Spacer(minLength: 6)
            if collapsed?.wrappedValue != true { accessory }
        }
        .onHover { hover = $0 }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

extension AgentSectionHeader where Accessory == EmptyView {
    init(title: String, collapsed: Binding<Bool>? = nil, count: Int? = nil) {
        self.title = title
        self.collapsed = collapsed
        self.count = count
        self.accessory = EmptyView()
    }
}

struct AgentAccountSwitcher: View {
    let info: ClaudeAccountInfo?
    var onOpenProject: (ClaudeProfile) -> Void
    @Environment(AppModel.self) private var app
    @State private var open = false
    @State private var hover = false
    @State private var showAdd = false
    @State private var removeTarget: ClaudeProfile?
    @State private var editEndpoint: ClaudeProfile?
    @State private var confirmLogout = false

    private var profiles: ClaudeProfiles { ClaudeProfiles.shared }
    private var allMode: Bool { app.claude.accountFilter == nil && profiles.hasSeveral }

    private func email(_ p: ClaudeProfile) -> String? {
        if let endpoint = p.endpoint { return endpoint.kind == .openRouter ? endpoint.kind.title : endpoint.host }
        return p.email ?? (p.id == profiles.activeID ? info?.email : nil)
    }

    private func plan(_ p: ClaudeProfile) -> String? {
        p.id == profiles.activeID ? (info?.subscription ?? p.plan) : p.plan
    }

    var body: some View {
        let active = profiles.active
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                if allMode {
                    ZStack {
                        ForEach(Array(profiles.visible.prefix(3).enumerated()), id: \.element.id) { index, p in
                            ProfileBadge(profile: p, size: 22)
                                .background(Circle().fill(Color.syPanel).padding(-1.5))
                                .offset(x: CGFloat(index) * 9 - 9)
                        }
                    }
                    .frame(width: 36, height: 28)
                } else {
                    ProfileBadge(profile: active, size: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(allMode ? "All accounts" : active.label)
                        .font(.syCallout.weight(.semibold))
                        .foregroundStyle(Color.syText)
                        .lineLimit(1)
                    Text(subtitle(active))
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.syCaption2.weight(.semibold))
                    .foregroundStyle(Color.syDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover || open ? Color.syText.opacity(0.06) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.micro)) { hover = h } }
        .help("Claude account")
        .accessibilityLabel(allMode ? "All Claude accounts" : "Claude account \(active.label)")
        .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        .modifier(ProfileSheets(showAdd: $showAdd, removeTarget: $removeTarget))
        .sheet(item: $editEndpoint) { AddClaudeProfileSheet(editing: $0) }
        .confirmationDialog("Sign out of Claude Code?", isPresented: $confirmLogout) {
            Button("Sign out", role: .destructive) { Task { await ClaudeAccountStore.shared.logout() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(active.isDefault ? "This also signs out Claude Code in Terminal. You can sign in again afterwards, including with another account." : "Signs out only “\(active.label)”. Other accounts are not affected.")
        }
    }

    private func subtitle(_ active: ClaudeProfile) -> String {
        if allMode { return "\(profiles.visible.count) accounts · new sessions as \(active.label)" }
        return [email(active), plan(active)].compactMap { $0 }.joined(separator: " · ")
    }

    private var panel: some View {
        let active = profiles.active
        return VStack(alignment: .leading, spacing: 2) {
            Text("CLAUDE ACCOUNTS")
                .font(.syCaption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(Color.syDim)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(profiles.visible) { p in
                AccountPanelRow(profile: p, email: email(p), plan: plan(p), checked: !allMode && p.id == active.id) { select(p) }
            }
            if profiles.hasSeveral {
                PanelActionRow(icon: "person.2", title: "All accounts", checked: allMode) {
                    app.claude.accountFilter = nil
                    open = false
                }
            }
            Divider().padding(.vertical, 4)
            PanelActionRow(icon: "folder.badge.plus", title: "Open project as \(active.label)…") { close { onOpenProject(active) } }
            PanelActionRow(icon: "pencil", title: "Rename “\(active.label)”…") { close { AgentRename.account(active) } }
            PanelActionRow(icon: "plus", title: "Add account…") { close { showAdd = true } }
            Divider().padding(.vertical, 4)
            if active.endpoint != nil {
                PanelActionRow(icon: "slider.horizontal.3", title: "Edit endpoint…") { close { editEndpoint = active } }
            } else {
                PanelActionRow(icon: "gauge.with.dots.needle.33percent", title: "Usage limits") { close { openInBrowser("https://claude.ai/settings/usage") } }
            }
            PanelActionRow(icon: "arrow.clockwise", title: "Refresh status") { close { Task { await ClaudeAccountStore.shared.refresh(force: true) } } }
            if active.isDefault {
                if active.endpoint == nil {
                    PanelActionRow(icon: "rectangle.portrait.and.arrow.right", title: "Sign out…", destructive: true) { close { confirmLogout = true } }
                }
            } else {
                PanelActionRow(icon: "trash", title: "Remove “\(active.label)”…", destructive: true) { close { removeTarget = active } }
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func close(_ action: @escaping () -> Void) {
        open = false
        DispatchQueue.main.async(execute: action)
    }

    /// Picking an account always narrows the list to it, including when
    /// coming from "All accounts"; "All accounts" is its own row.
    private func select(_ p: ClaudeProfile) {
        app.switchClaudeProfile(to: p.id)
        app.claude.accountFilter = profiles.hasSeveral ? p.id : nil
        open = false
    }
}

private struct AccountPanelRow: View {
    let profile: ClaudeProfile
    let email: String?
    let plan: String?
    let checked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProfileBadge(profile: profile, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.label).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
                    if let email {
                        Text(email).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let plan {
                    Text(plan)
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(Color.syMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.syText.opacity(0.07)))
                }
                Image(systemName: "checkmark")
                    .font(.syCaption.weight(.bold))
                    .foregroundStyle(Color.syAgentAccent)
                    .opacity(checked ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }
}

private struct PanelActionRow: View {
    let icon: String
    let title: String
    var checked = false
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.syCallout)
                    .foregroundStyle(destructive ? Color.syRed : Color.syMuted)
                    .frame(width: 26)
                Text(title)
                    .font(.syCallout)
                    .foregroundStyle(destructive ? Color.syRed : Color.syText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.syCaption.weight(.bold))
                        .foregroundStyle(Color.syAgentAccent)
                        .frame(width: 14)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AgentNewSessionRow: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syAgentAccent)
                    .frame(width: 18)
                Text("New session")
                    .font(.syBody.weight(.medium))
                    .foregroundStyle(Color.syText)
                Spacer(minLength: 6)
                Text("⌘N")
                    .font(.syCaption2.monospacedDigit())
                    .foregroundStyle(Color.syDim)
                    .opacity(hover ? 1 : 0.7)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Color.syText.opacity(0.07) : Color.syText.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.syLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.micro)) { hover = h } }
        .help("Start a new session in a project")
    }
}
