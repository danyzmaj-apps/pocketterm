import CoreImage
import CoreImage.CIFilterBuiltins
import PocketTermDesktop
import PocketTermKit
import SwiftUI

/// How long a phone's code works (POST /v1/pair).
let pairingLifetime: TimeInterval = 10 * 60

/// A QR the phone opens in PocketTerm (its Scan button, or the iPhone's Camera): the server's address, a one-time
/// sign-in code and this computer's channel key, so the phone is set up, signed in and able to read this computer by
/// the scan alone (a phone has no other way in). Anyone who scans it gets into the account and can read this
/// computer's sessions, so it is made fresh when shown, its sign-in works once, and it hides itself when it runs
/// out; the key stays good until Reset key (Settings → Phone).
struct PairingQrView: View {
  @EnvironmentObject var app: AppController

  private enum Code: Equatable {
    case making
    case made(URL)
    case failed(String)
  }

  @State private var code = Code.making
  @State private var expired = false
  /// Bumped by Retry / Make a new one: a fresh code and a fresh 10 minutes.
  @State private var round = 0

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if expired {
          placeholder("This code ran out.", action: "Make a new one")
        } else {
          switch code {
          case .making: ProgressView().controlSize(.small)
          case .failed(let why): placeholder(why, action: "Retry")
          case .made(let link):
            QrImage(text: link.absoluteString)
              .padding(10)
              .background(RoundedRectangle(cornerRadius: 12).fill(.white))
              .accessibilityLabel("Pairing code")
              .accessibilityIdentifier("pairing-qr")
          }
        }
      }
      .frame(width: 210, height: 210)
      Text(
        "On your phone: install PocketTerm and tap Scan the code from your computer "
          + "(on iPhone the Camera works too). It connects and signs in; nothing to type."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 14)
      Text(
        "This code is a secret. Anyone who scans it can read this computer's sessions. "
          + "The sign-in works once, for 10 minutes; the key in it works until you reset it in Settings."
      )
      .font(.callout)
      .multilineTextAlignment(.center)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity)
    .task(id: round) { await make() }
    .task(id: round) {
      // The code's sign-in stops working after its lifetime: hide it then, as the server would refuse it.
      try? await Task.sleep(nanoseconds: UInt64(pairingLifetime * 1_000_000_000))
      if !Task.isCancelled { expired = true }
    }
  }

  private func make() async {
    code = .making
    do {
      code = .made(try await app.pairingLink())
    } catch let e as PairingException {
      code = .failed(e.message)
    } catch {
      code = .failed("Couldn't make a code: \(error)")
    }
  }

  private func placeholder(_ text: String, action: String) -> some View {
    VStack(spacing: 8) {
      Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(action) {
        expired = false
        round += 1
      }
      .accessibilityIdentifier("pairing-renew")
    }
  }
}

/// `text` as a QR code: its modules drawn crisp (no smoothing) at any size, black on the white around it.
struct QrImage: View {
  let text: String

  var body: some View {
    if let image = Self.render(text) {
      Image(image, scale: 1, label: Text("Pairing code"))
        .interpolation(.none)
        .resizable()
        .aspectRatio(1, contentMode: .fit)
    } else {
      Color.white
    }
  }

  /// One pixel per module, no quiet zone of its own (the view puts the white around it).
  static func render(_ text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "L"
    guard let output = filter.outputImage else { return nil }
    // CIQRCodeGenerator adds a one-module margin; the padding around the image is the quiet zone instead.
    let modules = output.extent.insetBy(dx: 1, dy: 1)
    return CIContext().createCGImage(output, from: modules)
  }
}

/// Settings → Phone → "Add a phone…".
struct PairingSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SheetLayout(title: "Set up your phone", width: 360) {
      PairingQrView()
    } buttons: {
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
  }
}
