// swift-tools-version: 6.0
// PocketTerm's shared Swift code: the core both the iPhone and the Mac app use,
// the Mac's terminal hosts, and the Mac app's services. docs/ARCHITECTURE.md describes each part.
import PackageDescription

let package = Package(
  name: "PocketTermKit",
  platforms: [.iOS(.v17), .macOS(.v13)],
  products: [
    .library(name: "PocketTermKit", targets: ["PocketTermKit"]),
    .library(name: "PocketTermTerminals", targets: ["PocketTermTerminals"]),
    .library(name: "PocketTermDesktop", targets: ["PocketTermDesktop"]),
  ],
  dependencies: [
    // The Mac app's local API (127.0.0.1 HTTP + WebSocket for the coding agents' integrations).
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
  ],
  targets: [
    // Platform-neutral: end-to-end encryption, the server client, the live protocol, the phone's remote.
    .target(name: "PocketTermKit"),
    // macOS only: kitty, tmux, WezTerm, iTerm2 and Ghostty as one list of terminal windows.
    .target(name: "PocketTermTerminals", dependencies: ["PocketTermKit"]),
    // macOS only (empty elsewhere): the Mac app's services without its UI — the controller, the local API, the
    // live hub, the terminal bridge, the built-in server, integrations, Keychain and preference migration.
    .target(
      name: "PocketTermDesktop",
      dependencies: [
        "PocketTermKit",
        "PocketTermTerminals",
        .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS])),
        .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS])),
        .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.macOS])),
        .product(name: "NIOWebSocket", package: "swift-nio", condition: .when(platforms: [.macOS])),
      ],
      // README.md: the service surface the SwiftUI app builds on.
      exclude: ["README.md"]
    ),
    // Tests read tool/vectors/vectors.json from the repo (relative to #filePath), the frozen wire contract.
    .testTarget(name: "PocketTermKitTests", dependencies: ["PocketTermKit"]),
    .testTarget(name: "PocketTermTerminalsTests", dependencies: ["PocketTermTerminals"]),
    .testTarget(name: "PocketTermDesktopTests", dependencies: ["PocketTermDesktop"]),
  ]
)
