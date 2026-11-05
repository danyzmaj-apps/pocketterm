import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// A setup link for another computer, with what that computer does with it.
private struct ComputerLink: Identifiable {
  let url: URL
  let how: String
  var id: String { url.absoluteString }
}

/// A phone to sign out, asked first.
private struct PhoneToSignOut: Identifiable {
  let device: Device
  let name: String
  var id: String { device.id }
}

/// Settings → Account: who is signed in, the server and its phones, launch at login, erasing the server, the
/// theme, how data is protected, and the app's version, updates and Quit.
struct AccountTab: View {
  @EnvironmentObject private var app: AppController
  @EnvironmentObject private var status: StatusModel
  @EnvironmentObject private var updater: Updater
  @EnvironmentObject private var appearance: Appearance
  @State private var confirmSignOut = false
  @State private var phoneToSignOut: PhoneToSignOut?
  @State private var confirmErase = false
  @State private var addComputer: ComputerLink?
  @State private var serverMessage: String?
  @State private var eraseMessage: String?
  @State private var launchError: String?
  @State private var dataProtectionShown = false

  var body: some View {
    let hosting = app.hosting
    Section {
      HStack(spacing: 12) {
        Avatar(name: app.userName)
        VStack(alignment: .leading, spacing: 2) {
          Text(app.userName).fontWeight(.semibold)
          Text(
            hosting != nil
              ? "This computer runs your server"
              : app.backend?.isSupabase ?? false ? "Signed in to your Supabase project" : "Signed in to this server"
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Sign out", role: .destructive) { signOut() }
          .accessibilityIdentifier("settings-sign-out")
      }
    }
    .alert("Stop your server and sign out?", isPresented: $confirmSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Sign out", role: .destructive) { Task { await app.signOut() } }
    } message: {
      Text(
        "This computer runs your server. Signing out stops it, and your phones and other computers can’t "
          + "connect until you choose This computer again. What the server keeps stays on this computer."
      )
    }

    Section("Your server") {
      Text(serverLine)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("settings-server")
      ForEach((status.devices ?? []).filter { $0.role == .phone }, id: \.id) { d in
        let name = d.label.isEmpty ? "Phone" : d.label
        HStack {
          Label(name, systemImage: "iphone")
          Spacer()
          Button("Sign out…", role: .destructive) { phoneToSignOut = PhoneToSignOut(device: d, name: name) }
            .controlSize(.small)
            .accessibilityIdentifier("settings-phone-sign-out-\(d.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-phone-\(d.id)")
      }
      if let hosting {
        HostingStatusView(server: hosting)
        if hosting.state == .ready {
          Button("Add a computer…") { addBuiltInComputer() }
            .accessibilityIdentifier("settings-add-computer")
        }
      }
      if let supabase = app.server as? SupabaseServerClient {
        Button("Add a computer…") { addSupabaseComputer(supabase) }
          .accessibilityIdentifier("settings-add-computer")
      }
      InlineMessage(message: $serverMessage, error: true)
    }
    .alert(
      phoneToSignOut.map { "Sign out \($0.name)?" } ?? "",
      isPresented: Binding(get: { phoneToSignOut != nil }, set: { if !$0 { phoneToSignOut = nil } }),
      presenting: phoneToSignOut
    ) { phone in
      Button("Cancel", role: .cancel) {}
      Button("Sign out", role: .destructive) { signOutPhone(phone.device) }
    } message: { _ in
      Text(
        "It can no longer reach your server or get its notifications. To use it again, scan this computer’s "
          + "code on it (Settings → Phone → Add a phone…)."
      )
    }
    .sheet(item: $addComputer) { link in
      AddComputerSheet(link: link.url, how: link.how).appEnvironment(AppModel.shared)
    }

    Section {
      Toggle(isOn: Binding(get: { app.launchAtLogin ?? false }, set: { on in setLaunchAtLogin(on) })) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Launch at login")
          Text(launchError ?? "Start PocketTerm when you log in")
            .font(.caption)
            .foregroundStyle(launchError != nil ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .disabled(app.launchAtLogin == nil)
      .accessibilityIdentifier("settings-launch-at-login")
    }

    if app.hostsServer {
      Section {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Erase this server’s data")
            Text("Signs out every computer and phone and deletes what the server keeps")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Erase…", role: .destructive) { confirmErase = true }
            .accessibilityIdentifier("settings-erase")
        }
        InlineMessage(message: $eraseMessage, error: true)
      }
      .alert("Erase this server’s data?", isPresented: $confirmErase) {
        Button("Cancel", role: .cancel) {}
        Button("Erase", role: .destructive) { erase() }
      } message: {
        Text(
          "Every computer and phone is signed out of this server, and its images and push registrations "
            + "are deleted. This cannot be undone."
        )
      }
    }

    Section {
      ThemeTiles()
    } header: {
      Text("Theme")
    } footer: {
      Text("For this computer.").font(.caption).foregroundStyle(.secondary)
    }

    Section {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("How your data is protected")
          Text("End-to-end encryption, and what your server, Tailscale and the push relay can see")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Read…") { dataProtectionShown = true }
          .accessibilityIdentifier("settings-data-protection")
      }
    }
    .sheet(isPresented: $dataProtectionShown) { DataProtectionSheet().appEnvironment(AppModel.shared) }

    Section {
      HStack {
        Text("PocketTerm \(Updater.version)").foregroundStyle(.secondary)
        Spacer()
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!updater.canCheck)
          .accessibilityIdentifier("settings-check-updates")
        Button("Quit PocketTerm") { Task { await AppModel.shared.host.quit() } }
          .accessibilityIdentifier("settings-quit")
      }
    }
  }

  /// "Supabase, abc.supabase.co · 2 computers, 1 phone"; a computer running the server says where in its status.
  private var serverLine: String {
    var parts: [String] = []
    if app.hosting == nil, let backend = app.backend {
      parts.append(backend.isSupabase ? "Supabase, \(backend.host)" : backend.host)
    }
    if let devices = status.devices {
      let phones = devices.filter { $0.role == .phone }.count
      parts.append("\(StatusModel.count(devices.count - phones, "computer")), \(StatusModel.count(phones, "phone"))")
    }
    return parts.joined(separator: " · ")
  }

  /// Signing out of a server this computer runs stops it: asked first.
  private func signOut() {
    if app.hosting != nil {
      confirmSignOut = true
    } else {
      Task { await app.signOut() }
    }
  }

  private func signOutPhone(_ d: Device) {
    Task {
      do {
        try await app.revokeServerDevice(d.id)
      } catch {
        serverMessage = "Not signed out: \(error)"
      }
      await status.checkDevices()
    }
  }

  private func erase() {
    Task {
      do {
        try await app.eraseServer()
      } catch {
        eraseMessage = "Not erased: \(error)"
      }
      await status.checkDevices()
    }
  }

  private func setLaunchAtLogin(_ on: Bool) {
    Task {
      do {
        try await app.setLaunchAtLogin(on: on)
        launchError = nil
      } catch {
        launchError = "\(error)"
      }
    }
  }

  private func addBuiltInComputer() {
    Task {
      guard let link = await app.computerSetupLink() else { return }
      addComputer = ComputerLink(url: link, how: AddComputerSheet.tailscaleHow)
    }
  }

  /// A new setup link from the Supabase project; the one before stops working.
  private func addSupabaseComputer(_ server: SupabaseServerClient) {
    Task {
      do {
        let link = try await server.newSetupLink()
        addComputer = ComputerLink(url: link, how: AddComputerSheet.supabaseHow)
      } catch {
        serverMessage = "No link: \(error)"
      }
    }
  }
}

/// The signed-in server's initial in a circle.
private struct Avatar: View {
  let name: String

  var body: some View {
    Text(name.first.map { String($0).uppercased() } ?? "?")
      .font(.headline)
      .foregroundStyle(.white)
      .frame(width: 32, height: 32)
      .background(Circle().fill(Color.accentColor))
      .accessibilityHidden(true)
  }
}

/// A theme to pick, with its light and dark swatch; the one picked is tinted and outlined in the accent.
private struct ThemeTiles: View {
  @EnvironmentObject private var appearance: Appearance

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
      ForEach(ThemeChoice.allCases, id: \.self) { c in
        let on = appearance.choice == c
        let accent = themeAccent(c)
        Button {
          appearance.choose(c)
        } label: {
          HStack(spacing: 10) {
            ThemeSwatch(choice: c)
            Text(c.label).fontWeight(on ? .semibold : .regular)
            Spacer(minLength: 0)
          }
          .padding(6)
          .contentShape(Rectangle())
          .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent.opacity(0.18) : .clear))
          .overlay(
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(on ? accent : Color(nsColor: .separatorColor), lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("settings-theme-\(c.rawValue)")
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings-theme")
  }
}

/// A theme in small: its light half beside its dark half, each its background with its accent and two of its
/// colors.
private struct ThemeSwatch: View {
  let choice: ThemeChoice

  var body: some View {
    HStack(spacing: 0) {
      half(choice.light)
      half(choice.dark)
    }
    .clipShape(RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
  }

  private func half(_ theme: PtTheme) -> some View {
    HStack(spacing: 3) {
      Circle().fill(theme.platformAccent ? Color(nsColor: .controlAccentColor) : Color(theme.accent))
        .frame(width: 9, height: 9)
      Circle().fill(Color(theme.ok)).frame(width: 9, height: 9)
      Circle().fill(Color(theme.warn)).frame(width: 9, height: 9)
    }
    .padding(.horizontal, 6)
    .frame(height: 22)
    .background(Color(theme.win))
  }
}
