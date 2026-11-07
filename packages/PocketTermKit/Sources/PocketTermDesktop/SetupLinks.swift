#if os(macOS)
import Foundation
import PocketTermKit

/// What's wrong with a setup link pasted on the first-run setup (Join another computer's PocketTerm…): nil
/// when it signs this computer in, else what to do instead, worded for the person. The link comes from another
/// computer's Settings → Add a computer…, so its server is that computer's, on Tailscale
/// (`https://<name>.<tailnet>.ts.net`); [anyServer] (test builds) takes any server, as the e2e harness signs
/// in to one on 127.0.0.1.
public func setupLinkProblem(_ text: String, anyServer: Bool = false) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let link = DartUri(trimmed), link.scheme == "pocketterm", link.host == "setup",
    let url = link.queryParameters["url"]
  else {
    return "That isn’t a setup link. It starts with pocketterm://setup?url= : on the other computer, open "
      + "Settings, Add a computer… and copy the whole link."
  }
  let kind = link.queryParameters["kind"] ?? ""
  if !kind.isEmpty && kind != "pocketterm" { return notOnTailscale }
  guard let backend = Backend.fromLink(trimmed) else {
    if anyServer, let error = Backend.parse(url).error { return "The server address in that link doesn’t work. \(error)" }
    return notOnTailscale
  }
  if !anyServer && !isTailscaleServer(backend) { return notOnTailscale }
  if Backend.setupToken(trimmed) != nil { return nil }
  if Backend.pairingCode(trimmed) != nil {
    return "That link signs in a phone, not a computer. On the other computer, open Settings, Add a computer… "
      + "and paste the link it shows."
  }
  return "That link has no setup token. On the other computer, open Settings, Add a computer… and copy the "
    + "whole link."
}

let notOnTailscale = "This link isn't for a PocketTerm on Tailscale."

/// `https://<name>.<tailnet>.ts.net`: a computer's built-in server, published by `tailscale serve`.
func isTailscaleServer(_ backend: Backend) -> Bool {
  guard backend.url.hasPrefix("https://"), backend.onTailnet else { return false }
  let labels = backend.host.split(separator: ".", omittingEmptySubsequences: false)
  return labels.count == 4 && labels.allSatisfy { !$0.isEmpty } && DartUri(backend.url)?.port == nil
}
#endif
