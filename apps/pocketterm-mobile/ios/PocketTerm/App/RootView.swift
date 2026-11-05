import PocketTermKit
import SwiftUI

/// What the app shows at its root, by state: nothing yet while it reads what it kept; setup (or the demo) while
/// signed out; the push question once after a sign-in; else the home list. Pages and sheets over one root belong
/// to it: when the root changes (signed out here or by the computer, the demo left) they go with it.
struct RootView: View {
  @ObservedObject var app: AppModel
  @ObservedObject private var look = appearance

  var body: some View {
    Group {
      if app.user == nil && app.launching {
        LaunchView(look: look)
      } else if app.user == nil, let demo = app.demo {
        HomeRoot(app: app, demo: demo).id("demo")
      } else if app.user == nil {
        SetupView(app: app).id("setup")
      } else if app.pushEnabled == nil {
        PushConsentView(app: app).id("consent")
      } else {
        HomeRoot(app: app, demo: nil).id(app.user!.id)
      }
    }
    .themed(look)
    .toasts()
    .task { AppTips.configure(app.tips) }
  }
}

/// Until the app knows whether there's a sign-in: the launch screen's picture for the chosen theme on its
/// background, light or dark as the system is, so the first frame doesn't flash setup.
struct LaunchView: View {
  @ObservedObject var look: Appearance

  var body: some View {
    GeometryReader { g in
      Image(look.choice.launchIcon)
        .resizable()
        .scaledToFit()
        .frame(width: min(360, min(g.size.width, g.size.height) * 0.42))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(look.theme.win.color)
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

/// The home list in its navigation stack, with the pages it opens; one [HomeModel] for as long as this root
/// shows (one sign-in, or the demo).
struct HomeRoot: View {
  init(app: AppModel, demo: DemoComputer?) {
    _home = StateObject(
      wrappedValue: demo.map { d in HomeModel(app: app, desktops: d.desktops, remoteFor: { _, _ in d.remote }) }
        ?? HomeModel(app: app))
  }

  @StateObject private var home: HomeModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var askTour = false

  var body: some View {
    NavigationStack(path: $home.path) {
      HomeView(home: home)
        .navigationDestination(for: AppRoute.self) { route in
          if let remote = home.remote {
            switch route {
            case .session(let key, let starting, let after):
              SessionPage(home: home, remote: remote, sessionKey: key, starting: starting, after: after)
            case .terminal(let window, let starting):
              TerminalPage(home: home, remote: remote, window: window, starting: starting)
            }
          }
        }
    }
    .onChange(of: scenePhase) { _, phase in home.scenePhase(phase) }
    .onDisappear { home.dispose() }
    .task {
      // The first time on the list (also the demo's), whether to have the first-use tips. Not answered, it asks
      // again next time.
      if !home.app.tips.answered { askTour = true }
    }
    .sheet(isPresented: $askTour) {
      TourAskSheet { tour in
        askTour = false
        home.app.tips.answer(tour: tour)
      }
      .toasts()
    }
  }
}
