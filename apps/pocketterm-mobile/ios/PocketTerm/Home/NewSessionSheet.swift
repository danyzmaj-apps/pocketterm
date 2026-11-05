import PocketTermKit
import SwiftUI

/// A new terminal window in one of the computer's projects (or any folder typed in, or General: the home folder), or
/// in a new project folder made under one of the computer's Project folders, starting the computer's coding agent
/// unless turned off, in the omp profile picked when the computer has more than the default. [onOpened] gets the new
/// window and whether the agent runs in it; a refusal shows and the sheet stays to try again.
struct NewSessionSheet: View {
  @ObservedObject var remote: TerminalRemote
  let app: AppModel
  let onOpened: (Opened, _ agent: Bool) -> Void

  init(remote: TerminalRemote, app: AppModel, onOpened: @escaping (Opened, _ agent: Bool) -> Void) {
    self.remote = remote
    self.app = app
    self.onOpened = onOpened
    _profile = State(initialValue: app.newSessionProfile(remote.desktopId))
  }

  @Environment(\.dismiss) private var dismiss

  @State private var query = ""
  @State private var agent = true
  /// The folder (or root, for a new project) a window is opening in.
  @State private var launching: String?
  /// Making a new project: its [name] and the computer's root it goes in (the first while none is picked or the
  /// picked one is gone).
  @State private var creating = false
  @State private var name = ""
  @State private var rootPath: String?
  /// The omp profile picked; [chosen] is it while the computer has it.
  @State private var profile: String
  @FocusState private var nameFocused: Bool

  /// The omp profile the agent starts in: the one picked, while the computer has it; else the default.
  private var chosen: String { remote.agent == .omp && remote.profiles.contains(profile) ? profile : "" }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(isOn: $agent) {
            Text("Start \(remote.agent.label)")
            Text("Off: just a shell")
          }
          .accessibilityIdentifier("start-agent")
          if agent && remote.agent == .omp && !remote.profiles.isEmpty { profileChips }
        } header: {
          if let opensIn = remote.opensIn {
            // "Opens in kitty, as a tab in the project's window", when the computer says which.
            Text((["Opens in \(opensIn)"] + [remote.placement?.describe].compactMap { $0 }).joined(separator: ", "))
              .textCase(nil)
              .lineLimit(2)
              .accessibilityIdentifier("opens-in")
          }
        }
        if creating { createForm } else { pickList }
      }
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .top, spacing: 0) { LinkNoteBar(remote: remote) }
      .navigationTitle(creating ? "New project" : "New session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if creating {
            Button("Back") { creating = false }
              .disabled(launching != nil)
          } else {
            Button("Cancel") { dismiss() }
          }
        }
      }
    }
    .presentationDetents([.fraction(0.7), .large])
    .interactiveDismissDisabled(launching != nil)
  }

  /// The omp profiles to start in, the default first; a pick is kept for next time.
  private var profileChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach([""] + remote.profiles, id: \.self) { p in
          let picked = chosen == p
          Button {
            Haptics.picked()
            profile = p
            app.setNewSessionProfile(remote.desktopId, p)
          } label: {
            Text(p.isEmpty ? "default" : p)
              .font(.subheadline)
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .foregroundStyle(picked ? Color.white : Color.primary)
              .background(
                Capsule().fill(picked ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill))))
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(picked ? .isSelected : [])
          .accessibilityIdentifier("start-profile-\(p.isEmpty ? "default" : p)")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Profile")
    .accessibilityIdentifier("start-profile")
  }

  // MARK: Picking a folder

  /// Find a project (or type a path) and open a window there, or in General (the home folder: a quick question
  /// without picking a project); or start a new project.
  @ViewBuilder
  private var pickList: some View {
    let found = NewSessionPlaces(remote, query: query)
    let roots = remote.roots
    Section {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Find a project, or type ~/path", text: $query)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .keyboardType(.webSearch)
          .accessibilityIdentifier("session-folder")
      }
    } footer: {
      if found.noRootsHint {
        Text(
          "No project folders yet. On your computer, open PocketTerm → Settings → Project folders and add the "
            + "folders that hold your projects. You can still type a ~/path above."
        )
        .accessibilityIdentifier("no-roots")
      }
    }
    Section {
      if found.general {
        place(remote.home, open: found.open.contains(remote.home), name: "General", id: "place-general")
      }
      if query.isEmpty, let roots {
        Button {
          creating = true
        } label: {
          Label {
            Text("New project…")
            // The hint above says it already.
            if found.noRoots && !found.noRootsHint {
              Text("Add a project folder in PocketTerm on your computer: Settings → Project folders")
            }
          } icon: {
            Image(systemName: "folder.badge.plus")
          }
        }
        .disabled(!remote.online || roots.isEmpty || launching != nil)
        .accessibilityIdentifier("new-project")
      }
      ForEach(Array(([found.typed].compactMap { $0 } + found.places).enumerated()), id: \.offset) { _, p in
        place(p, open: found.open.contains(p))
      }
    }
  }

  /// A project's row, as the home list names it: the folder's name ([name] instead, if given), its short path in
  /// small under it, and a terminal for a folder a window is [open] in.
  private func place(_ path: String, open: Bool, name: String? = nil, id: String? = nil) -> some View {
    Button {
      launch(path)
    } label: {
      HStack {
        Label {
          Text(name ?? baseName(path))
            .foregroundStyle(.primary)
            .lineLimit(1)
          Text(shortPath(remote, path))
            .lineLimit(1)
        } icon: {
          Image(systemName: open ? "terminal" : "folder")
        }
        Spacer(minLength: 8)
        if launching == path { ProgressView() }
      }
    }
    .disabled(!remote.online || (launching != nil && launching != path))
    .accessibilityIdentifier(id ?? "place-\(path)")
  }

  private func launch(_ cwd: String) {
    guard launching == nil else { return }
    launching = cwd
    let agent = agent
    let profile = agent ? chosen : ""
    Task {
      do {
        let opened = try await remote.launch(cwd, startAgent: agent, profile: profile)
        launching = nil
        onOpened(opened, agent)
      } catch {
        launching = nil
        refused(error)
      }
    }
  }

  // MARK: A new project

  /// Name the project and pick the folder it goes in.
  @ViewBuilder
  private var createForm: some View {
    let roots = remote.roots ?? []
    let root = rootPath.flatMap { roots.contains($0) ? $0 : nil } ?? roots.first
    let busy = launching != nil
    let ready = remote.online && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
    Section {
      TextField("Project name", text: $name)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .focused($nameFocused)
        .submitLabel(.go)
        .onSubmit { if let root, ready { create(root) } }
        .accessibilityIdentifier("project-name")
    }
    .onAppear { nameFocused = true }
    Section("In") {
      Picker("In", selection: Binding(get: { root ?? "" }, set: { rootPath = $0 })) {
        ForEach(roots, id: \.self) { r in
          Text(shortPath(remote, r)).tag(r)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
      .disabled(busy)
    }
    Section {
      Button {
        if let root { create(root) }
      } label: {
        HStack {
          Text("Create and open")
          Spacer()
          if busy { ProgressView() }
        }
      }
      .disabled(root == nil || !ready)
      .accessibilityIdentifier("create-project")
    }
  }

  /// Makes [name] under [root] on the computer and opens a window there, as [launch].
  private func create(_ root: String) {
    guard launching == nil else { return }
    launching = root
    let agent = agent
    let profile = agent ? chosen : ""
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    Task {
      do {
        let opened = try await remote.create(root, name, startAgent: agent, profile: profile)
        launching = nil
        onOpened(opened, agent)
      } catch {
        launching = nil
        refused(error)
      }
    }
  }

  /// The computer said no (or didn't answer): it shows, and the form stays to try again.
  private func refused(_ error: Error) {
    Haptics.failed()
    Toaster.shared.show(errorText(error))
  }
}
