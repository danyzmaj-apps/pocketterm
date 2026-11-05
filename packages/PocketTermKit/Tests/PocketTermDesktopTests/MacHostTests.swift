#if os(macOS)
import Foundation
import IOKit.pwr_mgt
import ServiceManagement
import XCTest

@testable import PocketTermDesktop

final class MacHostTests: XCTestCase {
  @MainActor
  private func host(_ item: SystemFakeLoginItem) -> MacHost {
    MacHost(showWindow: { XCTFail("window shown") }, hideWindow: {}, loginItem: item)
  }

  @MainActor
  private func error(_ body: () async throws -> Void) async -> String? {
    do {
      try await body()
      return nil
    } catch {
      return (error as? LaunchAtLoginError)?.message ?? "not a LaunchAtLoginError: \(error)"
    }
  }

  @MainActor
  func testALoginItemMacOSLeftOffWaitingForApprovalThrowsSayingWhereToAllowIt() async {
    let item = SystemFakeLoginItem()
    item.after = .requiresApproval
    let message = await error { try await self.host(item).setLaunchAtLogin(on: true) }
    XCTAssertEqual(message, "Allow PocketTerm in System Settings > General > Login Items.")
    XCTAssertEqual(item.calls, ["register"])
  }

  @MainActor
  func testALoginItemMacOSDidntEnableThrowsTheSame() async {
    let item = SystemFakeLoginItem()
    item.after = .notRegistered
    let message = await error { try await self.host(item).setLaunchAtLogin(on: true) }
    XCTAssertEqual(message, MacHost.loginItemsHint)
  }

  @MainActor
  func testALoginItemMacOSKeepsAfterTurningItOffThrows() async {
    let item = SystemFakeLoginItem(status: .enabled)
    item.after = .enabled
    let message = await error { try await self.host(item).setLaunchAtLogin(on: false) }
    XCTAssertEqual(
      message, "macOS still starts PocketTerm at login. Turn it off in System Settings > General > Login Items.")
    XCTAssertEqual(item.calls, ["unregister"])
  }

  @MainActor
  func testARefusalSaysWhatMacOSSaid() async {
    let item = SystemFakeLoginItem()
    item.refuse = NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nope."])
    let message = await error { try await self.host(item).setLaunchAtLogin(on: true) }
    XCTAssertEqual(message, "Nope.")
  }

  @MainActor
  func testDoneAsAskedNoError() async throws {
    let item = SystemFakeLoginItem()
    let host = host(item)
    try await host.setLaunchAtLogin(on: true)
    var on = await host.launchAtLogin()
    XCTAssertTrue(on)
    try await host.setLaunchAtLogin(on: false)
    on = await host.launchAtLogin()
    XCTAssertFalse(on)
    XCTAssertEqual(item.calls, ["register", "unregister"])
  }

  @MainActor
  func testKeepingAwakeHoldsOneAssertionUntilTurnedOff() async throws {
    let host = host(SystemFakeLoginItem())
    await host.setKeepAwake(on: true)
    let id = try XCTUnwrap(host.awake)
    await host.setKeepAwake(on: true)
    XCTAssertEqual(host.awake, id)
    var props = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
    XCTAssertEqual(props?[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleSystemSleep)
    await host.setKeepAwake(on: false)
    XCTAssertNil(host.awake)
    props = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
    XCTAssertNil(props)
    await host.setKeepAwake(on: false)
  }

  @MainActor
  func testQuittingWaitsForTheControllerAtMostTheLimit() async {
    let host = host(SystemFakeLoginItem())
    var heard: [String] = []
    await host.start { event in
      heard.append(event)
      try? await Task.sleep(for: .seconds(30))
    }
    let clock = ContinuousClock.now
    await host.quitting(within: .milliseconds(100))
    XCTAssertLessThan(ContinuousClock.now - clock, .seconds(5))
    XCTAssertEqual(heard, ["quitting"])
  }

  @MainActor
  func testQuittingReturnsOnceTheControllerIsDone() async {
    let host = host(SystemFakeLoginItem())
    var done = false
    await host.start { _ in done = true }
    await host.quitting(within: .seconds(30))
    XCTAssertTrue(done)
  }
}
#endif
