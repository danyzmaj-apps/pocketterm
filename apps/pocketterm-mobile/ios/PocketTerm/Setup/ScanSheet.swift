import AVFoundation
import PocketTermKit
import SwiftUI
import UIKit
import VisionKit

/// What a scanned (or, in E2E builds, pasted) code holds for the scanner: the first usable PocketTerm link, or
/// why none was. A phone signing in needs a sign-in code in it; a signed-in phone adding a computer needs that
/// computer's key.
nonisolated enum ScannedCode: Equatable {
  case link(URL)
  case problem(String)

  static let noKey =
    "That code has no key for a computer. Update PocketTerm on your computer, then scan its code in "
    + "Settings \u{2192} Phone \u{2192} Add a phone\u{2026}"
  static let noSignIn =
    "That code has no sign-in in it. Scan the one under Your phone in PocketTerm\u{2019}s setup checklist "
    + "on your computer, or in its Settings \u{2192} Phone \u{2192} Add a phone\u{2026}"
  static let notOurs = "That's not a PocketTerm code. Scan the one on your computer."

  /// [codes]: what the camera read at once (it may see several). A Wi-Fi code or a website is no PocketTerm
  /// code; a PocketTerm code without what this phone needs says what's missing.
  static func read(_ codes: [String?], signedIn: Bool) -> ScannedCode {
    var problem: String?
    for raw in codes {
      let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard let link = URL(string: text), Backend.fromLink(text) != nil else { continue }
      let usable = signedIn ? Backend.computerKey(text) != nil : Backend.pairingCode(text) != nil
      if usable { return .link(link) }
      problem = signedIn ? noKey : noSignIn
    }
    return .problem(problem ?? notOurs)
  }
}

/// Why the camera shows nothing: not allowed (with the way to Settings), no camera at all (an iPad or phone
/// without one, the Simulator), or it failed to start.
nonisolated enum CameraProblem: Equatable {
  case denied
  case unsupported
  case failed(String)

  var text: String {
    switch self {
    case .denied:
      "PocketTerm needs the camera to read the code. Allow it in Settings \u{2192} PocketTerm \u{2192} Camera."
    case .unsupported:
      "This device has no camera PocketTerm can use, so it can't read the code. Connect with a phone that has "
        + "one, or close this and try the demo."
    case .failed(let reason): "The camera didn't start (\(reason)). Close this and try again."
    }
  }
}

/// Reads the code the computer shows (Settings → Add a phone…) with the camera: a setup link with a sign-in
/// code in it or, when [signedIn] (a phone adding a computer's key), with that computer's key. Calls [onDone]
/// with that link, or nil when cancelled. E2E builds also take the link in a field, as if the camera had read
/// it: the Simulator has no camera. Present it with `.fullScreenCover`.
struct ScanSheet: View {
  init(signedIn: Bool, onDone: @escaping (URL?) -> Void) {
    self.signedIn = signedIn
    self.onDone = onDone
  }

  private let signedIn: Bool
  private let onDone: (URL?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var camera: CameraState = .starting
  @State private var done = false
  /// Set when a code was read that isn't a usable PocketTerm code (a Wi-Fi code, a website).
  @State private var notOurs: String?
  @State private var readCount = 0

  private enum CameraState: Equatable {
    case starting
    case running(QRCamera.Kind)
    case problem(CameraProblem)
  }

  private static let box: CGFloat = 260
  private static let hint =
    "On your computer: Your phone in PocketTerm\u{2019}s setup checklist, or Settings \u{2192} Phone \u{2192} "
    + "Add a phone\u{2026}\nPoint this camera at the code."

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      switch camera {
      case .starting:
        ProgressView().tint(.white)
      case .running(let kind):
        QRCamera(kind: kind, onCodes: read, onProblem: { camera = .problem($0) })
          .ignoresSafeArea()
        frame
      case .problem(let problem):
        CameraProblemView(problem: problem)
      }
    }
    .overlay(alignment: .topLeading) {
      Button {
        finish(nil)
      } label: {
        Image(systemName: "xmark")
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Circle())
      }
      .padding(.leading, 12)
      .padding(.top, 4)
      .accessibilityLabel("Cancel")
      .accessibilityIdentifier("scan-cancel")
    }
    .safeAreaInset(edge: .bottom) {
      if E2E.enabled {
        // Why a code didn't work shows under the square, unless the camera's problem took the screen.
        PasteCodeField(problem: isProblem ? notOurs : nil) { read([$0]) }
      }
    }
    .environment(\.colorScheme, .dark)
    .sensoryFeedback(.warning, trigger: readCount)
    .task { camera = await Self.startCamera() }
  }

  private var isProblem: Bool {
    if case .problem = camera { return true }
    return false
  }

  /// The square the code goes in, everything around it dimmed, and the hint (or why a code didn't work) under it.
  private var frame: some View {
    ZStack {
      Rectangle()
        .fill(.black.opacity(0.6))
        .mask {
          Rectangle()
            .overlay {
              RoundedRectangle(cornerRadius: 24, style: .continuous)
                .frame(width: Self.box, height: Self.box)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
        .ignoresSafeArea()
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(.white, lineWidth: 3)
        .frame(width: Self.box, height: Self.box)
      Text(notOurs ?? Self.hint)
        .font(.callout)
        .multilineTextAlignment(.center)
        .foregroundStyle(notOurs == nil ? Color.white : Color.orange)
        .padding(.horizontal, 32)
        .padding(.top, Self.box + 80)
        .accessibilityIdentifier("scan-hint")
    }
    .allowsHitTesting(false)
  }

  /// What the camera (or the paste field) read: the first usable PocketTerm link closes the scanner with it;
  /// otherwise it says why none was.
  private func read(_ codes: [String?]) {
    if done { return }
    switch ScannedCode.read(codes, signedIn: signedIn) {
    case .link(let link):
      Haptics.done()
      finish(link)
    case .problem(let problem):
      if notOurs != problem {
        notOurs = problem
        readCount += 1
      }
    }
  }

  private func finish(_ link: URL?) {
    if done { return }
    done = true
    onDone(link)
    dismiss()
  }

  /// Which camera can read codes here: none (no camera, not allowed), VisionKit's scanner where the phone has
  /// it, else AVFoundation's. Asks for the camera the first time.
  private static func startCamera() async -> CameraState {
    // The Simulator and phones without a camera: no question about a camera that isn't there.
    guard AVCaptureDevice.default(for: .video) != nil else { return .problem(.unsupported) }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: break
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .video) else { return .problem(.denied) }
    default: return .problem(.denied)
    }
    return .running(DataScannerViewController.isSupported ? .vision : .capture)
  }
}

/// Why the camera shows nothing, with the way to Settings when it wasn't allowed.
private struct CameraProblemView: View {
  let problem: CameraProblem

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        Image(systemName: problem == .denied ? "camera.badge.ellipsis" : "video.slash")
          .font(.system(size: 40))
          .foregroundStyle(.white.opacity(0.7))
          .accessibilityHidden(true)
        Text(problem.text)
          .multilineTextAlignment(.center)
          .foregroundStyle(.white)
          .accessibilityIdentifier("camera-problem")
        if problem == .denied {
          Button("Open Settings") { Push.openSettings() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("camera-settings")
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center)
  }
}

/// E2E builds only: a code's link, pasted instead of scanned.
private struct PasteCodeField: View {
  let problem: String?
  let onCode: (String) -> Void
  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let problem {
        Text(problem)
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      HStack(spacing: 8) {
        // A link: a keyboard that "corrects" url= to URL= breaks it.
        TextField("Paste a code (debug)", text: $text)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textContentType(.URL)
          .submitLabel(.go)
          .onSubmit { onCode(text) }
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("paste-code")
        Button("Use") { onCode(text) }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("paste-code-use")
      }
    }
    .padding(16)
    .background(.ultraThinMaterial)
  }
}

/// The camera, reading QR codes: VisionKit's DataScannerViewController where the phone has it (A12 and later),
/// else an AVCaptureSession with a metadata output.
struct QRCamera: UIViewControllerRepresentable {
  enum Kind: Equatable {
    case vision
    case capture
  }

  let kind: Kind
  let onCodes: ([String?]) -> Void
  let onProblem: (CameraProblem) -> Void

  func makeUIViewController(context: Context) -> QRCameraController {
    let controller: QRCameraController = kind == .vision ? VisionQRController() : CaptureQRController()
    controller.onCodes = onCodes
    controller.onProblem = onProblem
    return controller
  }

  func updateUIViewController(_ controller: QRCameraController, context: Context) {
    controller.onCodes = onCodes
    controller.onProblem = onProblem
  }

  static func dismantleUIViewController(_ controller: QRCameraController, coordinator: ()) {
    controller.stop()
  }
}

/// A camera that hands over the QR codes it reads ([onCodes]) and says when it can't run ([onProblem]).
class QRCameraController: UIViewController {
  var onCodes: ([String?]) -> Void = { _ in }
  var onProblem: (CameraProblem) -> Void = { _ in }

  func stop() {}

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
  }
}

/// VisionKit's scanner, QR codes only, without its own highlights: the sheet draws the square.
final class VisionQRController: QRCameraController, DataScannerViewControllerDelegate {
  private let scanner = DataScannerViewController(
    recognizedDataTypes: [.barcode(symbologies: [.qr])],
    qualityLevel: .balanced,
    recognizesMultipleItems: false,
    isHighFrameRateTrackingEnabled: false,
    isPinchToZoomEnabled: true,
    isGuidanceEnabled: false,
    isHighlightingEnabled: false
  )

  override func viewDidLoad() {
    super.viewDidLoad()
    scanner.delegate = self
    addChild(scanner)
    scanner.view.frame = view.bounds
    scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(scanner.view)
    scanner.didMove(toParent: self)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    do {
      try scanner.startScanning()
    } catch DataScannerViewController.ScanningUnavailable.cameraRestricted {
      onProblem(.denied)
    } catch DataScannerViewController.ScanningUnavailable.unsupported {
      onProblem(.unsupported)
    } catch {
      onProblem(.failed(error.localizedDescription))
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stop()
  }

  override func stop() { scanner.stopScanning() }

  func dataScanner(
    _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
  ) {
    let codes: [String?] = addedItems.compactMap {
      if case .barcode(let code) = $0 { return code.payloadStringValue }
      return nil
    }
    if !codes.isEmpty { onCodes(codes) }
  }

  func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
    onProblem(error == .cameraRestricted ? .denied : .unsupported)
  }
}

/// The session runs on its own queue: starting it blocks.
nonisolated private final class CaptureBox: @unchecked Sendable {
  let session = AVCaptureSession()
}

/// AVFoundation's QR reading, for phones without VisionKit's scanner.
final class CaptureQRController: QRCameraController, AVCaptureMetadataOutputObjectsDelegate {
  private let box = CaptureBox()
  private var preview: AVCaptureVideoPreviewLayer?
  private var ready = false
  private var failure: NSObjectProtocol?

  override func viewDidLoad() {
    super.viewDidLoad()
    guard let device = AVCaptureDevice.default(for: .video) else { return onProblem(.unsupported) }
    let session = box.session
    let output = AVCaptureMetadataOutput()
    do {
      let input = try AVCaptureDeviceInput(device: device)
      session.beginConfiguration()
      guard session.canAddInput(input), session.canAddOutput(output) else {
        session.commitConfiguration()
        return onProblem(.unsupported)
      }
      session.addInput(input)
      session.addOutput(output)
      session.commitConfiguration()
    } catch {
      return onProblem(.failed(error.localizedDescription))
    }
    guard output.availableMetadataObjectTypes.contains(.qr) else { return onProblem(.unsupported) }
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]
    let layer = AVCaptureVideoPreviewLayer(session: session)
    layer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(layer)
    preview = layer
    ready = true
    failure = NotificationCenter.default.addObserver(
      forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
    ) { [weak self] note in
      let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
      let reason = error?.localizedDescription ?? "error"
      MainActor.assumeIsolated { self?.onProblem(.failed(reason)) }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    preview?.frame = view.bounds
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard ready else { return }
    let box = box
    DispatchQueue.global(qos: .userInitiated).async { box.session.startRunning() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stop()
  }

  override func stop() {
    if let failure { NotificationCenter.default.removeObserver(failure) }
    failure = nil
    let box = box
    DispatchQueue.global(qos: .userInitiated).async { if box.session.isRunning { box.session.stopRunning() } }
  }

  nonisolated func metadataOutput(
    _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection
  ) {
    let codes: [String?] = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
    guard !codes.isEmpty else { return }
    // Delivered on the main queue (setMetadataObjectsDelegate's).
    MainActor.assumeIsolated { onCodes(codes) }
  }
}
