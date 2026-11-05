#if os(macOS)
import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import PocketTermKit

/// LocalApi's connections on the event loop: HTTP requests are read there, and answered by LocalApi on the main
/// actor; /v1/live upgrades to a WebSocket whose text frames stream to the hub.

/// The most a WebSocket message may hold (Dart's WebSocket had no cap; chat images ride in frames).
let maxSocketFrame = 64 * 1024 * 1024

/// Every accepted connection, so stopping can end them all (long polls included).
final class ChildChannels: @unchecked Sendable {
  private let lock = NSLock()
  private var open: [ObjectIdentifier: Channel] = [:]

  func add(_ channel: Channel) {
    let key = ObjectIdentifier(channel)
    lock.withLock { open[key] = channel }
    channel.closeFuture.whenComplete { [self] _ in _ = lock.withLock { open.removeValue(forKey: key) } }
  }

  func all() -> [Channel] { lock.withLock { Array(open.values) } }
}

/// The pipeline of one connection: HTTP, upgraded to a WebSocket on /v1/live with the token.
func configureChild(_ channel: Channel, api: LocalApi, token: String) -> EventLoopFuture<Void> {
  let upgrader = NIOWebSocketServerUpgrader(
    maxFrameSize: maxSocketFrame,
    shouldUpgrade: { ch, head in
      let ok = LocalApi.splitUri(head.uri).0 == "/v1/live"
        && head.headers.first(name: "authorization") == "Bearer \(token)"
      return ch.eventLoop.makeSucceededFuture(ok ? HTTPHeaders() : nil)
    },
    upgradePipelineHandler: { ch, _ in
      ch.eventLoop.makeCompletedFuture {
        try ch.pipeline.syncOperations.addHandler(
          NIOWebSocketFrameAggregator(
            minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: Int.max, maxAccumulatedFrameSize: maxSocketFrame))
        try ch.pipeline.syncOperations.addHandler(SocketHandler(api: api))
      }
    }
  )
  return channel.eventLoop.makeCompletedFuture {
    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
      withServerUpgrade: (
        upgraders: [upgrader],
        completionHandler: { ctx in ctx.pipeline.removeHandler(name: "pocketterm-http", promise: nil) }
      )
    )
    try channel.pipeline.syncOperations.addHandler(HTTPHandler(api: api, token: token), name: "pocketterm-http")
  }
}

/// One HTTP connection's requests, one at a time (NIO's pipelining handler holds the next).
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private enum Mode {
    /// Answered from the head alone; the body is read and dropped.
    case fixed(Int, String)
    /// A long poll's body, read up to LocalApi.maxBody.
    case collect
    /// Over the cap: read and dropped, then refused.
    case tooLarge
  }

  private let api: LocalApi
  private let token: String
  private var mode = Mode.fixed(400, "")
  private var body = ByteBuffer()
  private var keepAlive = true

  init(api: LocalApi, token: String) {
    self.api = api
    self.token = token
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      keepAlive = head.isKeepAlive
      body.clear()
      mode = route(head, port: context.channel.localAddress?.port ?? 0)
    case .body(var chunk):
      guard case .collect = mode else { return }
      if body.readableBytes + chunk.readableBytes > LocalApi.maxBody {
        mode = .tooLarge
        body = ByteBuffer()
      } else {
        body.writeBuffer(&chunk)
      }
    case .end:
      switch mode {
      case .fixed(let status, let text):
        respond(context, status, text)
      case .tooLarge:
        respond(context, 413, #"{"error":"Request over \#(LocalApi.maxBody / (1024 * 1024)) MiB."}"#)
      case .collect:
        let data = Data(body.readableBytesView)
        body = ByteBuffer()
        let promise = context.eventLoop.makePromise(of: Reply.self)
        let api = api
        Task { @MainActor in
          let (status, text) = await api.poll(data)
          promise.succeed(Reply(status: status, body: text))
        }
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        promise.futureResult.whenSuccess { reply in
          let (handler, context) = bound.value
          handler.respond(context, reply.status, reply.body)
        }
      }
    }
  }

  private func route(_ head: HTTPRequestHead, port: Int) -> Mode {
    let auth = head.headers.first(name: "authorization")
    switch LocalApi.splitUri(head.uri).0 {
    case "/v1/live":
      // A WebSocket upgrade with the token never gets here.
      return .fixed(403, "")
    case "/v1/live/http":
      if head.method != .POST { return .fixed(405, "") }
      if auth != "Bearer \(token)" { return .fixed(403, LocalApi.badToken) }
      if let length = head.headers.first(name: "content-length").flatMap(Int.init), length > LocalApi.maxBody {
        return .tooLarge
      }
      return .collect
    default:
      let (status, text) = LocalApi.route(
        method: head.method.rawValue, uri: head.uri, authorization: auth, token: token, port: port)
      return .fixed(status, text)
    }
  }

  private func respond(_ context: ChannelHandlerContext, _ status: Int, _ text: String) {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json; charset=utf-8")
    headers.add(name: "content-length", value: "\(text.utf8.count)")
    if !keepAlive { headers.add(name: "connection", value: "close") }
    let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    if !text.isEmpty {
      context.write(wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: text)))), promise: nil)
    }
    let done = context.eventLoop.makePromise(of: Void.self)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: done)
    if !keepAlive {
      let channel = context.channel
      done.futureResult.whenComplete { _ in channel.close(promise: nil) }
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // NIO refuses a /v1/live upgrade (no token, a wrong one) with an error rather than passing the request on.
    // NIO's HTTP handlers count that request as never read, so the answer goes out beneath them.
    if error is NIOWebSocketUpgradeError,
      let encoder = try? context.pipeline.syncOperations.context(handlerType: HTTPResponseEncoder.self)
    {
      let text = "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
      let channel = context.channel
      encoder.writeAndFlush(NIOAny(channel.allocator.buffer(string: text))).whenComplete { _ in
        channel.close(promise: nil)
      }
      return
    }
    context.close(promise: nil)
  }
}

struct Reply: Sendable {
  let status: Int
  let body: String
}

/// A /v1/live WebSocket after the upgrade: text frames to the hub, pings answered, a close echoed.
final class SocketHandler: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame

  private let api: LocalApi
  private var input: AsyncStream<String>.Continuation?
  private var closeSent = false

  init(api: LocalApi) { self.api = api }

  func handlerAdded(context: ChannelHandlerContext) {
    let (frames, input) = AsyncStream.makeStream(of: String.self)
    self.input = input
    let channel = context.channel
    let api = api
    Task { @MainActor in await api.acceptSocket(frames, channel) }
  }

  func channelInactive(context: ChannelHandlerContext) {
    input?.finish()
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) { input?.finish() }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = unwrapInboundIn(data)
    switch frame.opcode {
    case .text:
      var data = frame.unmaskedData
      input?.yield(data.readString(length: data.readableBytes) ?? "")
    case .ping:
      let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
      context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
    case .connectionClose:
      // The agent's close: answered with its code, then the connection ends.
      if closeSent {
        context.close(promise: nil)
        return
      }
      closeSent = true
      var data = frame.unmaskedData
      let code = data.readSlice(length: min(2, data.readableBytes)) ?? ByteBuffer()
      let reply = WebSocketFrame(fin: true, opcode: .connectionClose, data: code)
      let channel = context.channel
      context.writeAndFlush(wrapOutboundOut(reply)).whenComplete { _ in channel.close(promise: nil) }
    default:
      _ = frame
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }
}

/// A live session's WebSocket as its LiveLink.
@MainActor
final class WebSocketLink: LiveLink {
  private let channel: Channel

  init(_ channel: Channel) { self.channel = channel }

  func send(_ frame: String) {
    let data = channel.allocator.buffer(string: frame)
    channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: data), promise: nil)
  }

  func close() async { _ = try? await closeChannel(code: nil).get() }

  /// A close frame (with `code`, none like Dart's `close()` without one), then the connection ends.
  func closeChannel(code: WebSocketErrorCode?) -> EventLoopFuture<Void> {
    var data = channel.allocator.buffer(capacity: 2)
    if let code { data.write(webSocketErrorCode: code) }
    let channel = channel
    return channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .connectionClose, data: data))
      .flatMapError { _ in channel.eventLoop.makeSucceededVoidFuture() }
      .flatMap { channel.close() }
      .flatMapError { _ in channel.eventLoop.makeSucceededVoidFuture() }
  }
}
#endif
