import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// One Settings tab (Phone, Coding agents, Terminals, Account): the status section, then the tab's own, in a
/// grouped form that scrolls when the window is short.
struct SettingsTabView: View {
  let tab: SettingsTab
  @EnvironmentObject private var ui: UIState
  @EnvironmentObject private var status: StatusModel

  var body: some View {
    Form {
      StatusSection()
      switch tab {
      case .phone: PhoneTab()
      case .agents: AgentsTab()
      case .terminals: TerminalsTab()
      case .account: AccountTab()
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("settings-content")
    // Every tab may ask (its own rows, the status section); only the one showing asks the person.
    .confirmAgentInstall(tab == ui.settingsTab ? $status.installRequest : .constant(nil)) { agent in
      status.install(agent)
    }
    .linkNotice(when: true)
    .frame(minWidth: 600, idealWidth: 680, minHeight: 420, idealHeight: 620)
  }
}

/// Settings' top: all set, or what needs attention (listed on Show); and the way back to the setup checklist.
private struct StatusSection: View {
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel

  var body: some View {
    let items = status.items
    let n = items.count
    let ok = !status.checking && n == 0
    Section {
      HStack(spacing: 10) {
        // Not a spinner: a look may take a while (claude), and nothing moves meanwhile.
        Image(systemName: status.checking ? "ellipsis.circle" : ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(status.checking ? Color.secondary : ok ? Color.green : Color.orange)
          .imageScale(.large)
        VStack(alignment: .leading, spacing: 2) {
          Text(
            status.checking
              ? "Checking this computer…" : ok ? "All set" : "\(n) \(n == 1 ? "thing needs" : "things need") attention"
          )
          .fontWeight(.semibold)
          if n > 0 {
            Text(items.map(\.short).joined(separator: " · "))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        Spacer(minLength: 8)
        if n > 0 {
          Button(status.showAttention ? "Hide" : "Show") { status.showAttention.toggle() }
            .buttonStyle(.link)
            .accessibilityIdentifier("settings-status-show")
        }
        Button("Open setup checklist") { app.setGetReadyDone(false) }
          .buttonStyle(.link)
          .accessibilityIdentifier("settings-open-checklist")
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("settings-status")
      if status.showAttention && n > 0 {
        ForEach(items) { item in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.text)
              .font(.callout)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let a = item.action {
              Button(a.label) { a.run() }
                .controlSize(.small)
                .accessibilityIdentifier(a.id)
            }
          }
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("settings-attention-\(item.id)")
        }
      }
    }
  }
}
