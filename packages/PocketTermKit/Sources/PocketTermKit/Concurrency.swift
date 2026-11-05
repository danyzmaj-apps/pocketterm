import Foundation

/// Hands each value to every stream made by [stream] (Dart's broadcast `StreamController`): a stream made
/// after [finish] ends at once.
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
  private var finished = false

  public init() {}

  /// A new listener: every value sent from now on, until [finish].
  public func stream() -> AsyncStream<Element> {
    AsyncStream { c in
      let id = UUID()
      lock.lock()
      if finished {
        lock.unlock()
        c.finish()
        return
      }
      continuations[id] = c
      lock.unlock()
      c.onTermination = { [weak self] _ in
        guard let self else { return }
        self.lock.lock()
        self.continuations[id] = nil
        self.lock.unlock()
      }
    }
  }

  public func send(_ value: Element) {
    lock.lock()
    let all = Array(continuations.values)
    lock.unlock()
    for c in all { c.yield(value) }
  }

  public func finish() {
    lock.lock()
    finished = true
    let all = Array(continuations.values)
    continuations = [:]
    lock.unlock()
    for c in all { c.finish() }
  }

  public var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }
}

/// A value behind a lock, for state shared across threads.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func with<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }

  var get: Value { with { $0 } }
}

/// [body]'s result, or [TimeoutError] after [seconds].
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws
  -> T
{
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      throw TimeoutError()
    }
    defer { group.cancelAll() }
    return try await group.next()!
  }
}

/// Something took longer than it may.
public struct TimeoutError: Error, Sendable {}

/// A timer on the main actor (Dart's `Timer`): [cancel] stops it before it fires.
@MainActor
public final class MainTimer {
  private var task: Task<Void, Never>?

  /// Fires [action] once after [seconds].
  public init(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    task = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
      guard !Task.isCancelled, self?.task != nil else { return }
      self?.task = nil
      action()
    }
  }

  /// Fires [action] every [seconds] until cancelled.
  public init(every seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        guard !Task.isCancelled, self?.task != nil else { return }
        action()
      }
    }
  }

  public var isActive: Bool { task != nil }

  public func cancel() {
    task?.cancel()
    task = nil
  }
}
