#if os(macOS)
import Foundation
import PocketTermKit

/// What's wrong with a setup link pasted on the first-run setup (Have a server, Supabase → Paste a setup link):
/// nil when it signs this computer in, else what to do instead, worded for the person.
public func setupLinkProblem(_ text: String) -> String? {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let link = DartUri(trimmed), link.scheme == "pocketterm", link.host == "setup",
    let url = link.queryParameters["url"]
  else {
    return "That isn’t a setup link. It starts with pocketterm://setup?url= : copy the whole line setup-link "
      + "printed."
  }
  let kind = link.queryParameters["kind"] ?? ""
  let supabase = kind == BackendKind.supabase.rawValue
  if Backend.fromLink(trimmed) == nil {
    if !kind.isEmpty && kind != BackendKind.pocketterm.rawValue && !supabase {
      return "That link is for a newer PocketTerm. Update PocketTerm, then paste it again."
    }
    if let error = Backend.parse(url, kind: supabase ? .supabase : .pocketterm).error {
      return "The server address in that link doesn’t work. \(error)"
    }
  }
  if Backend.setupToken(trimmed) != nil { return nil }
  if supabase {
    return Backend.pairingCode(trimmed) != nil
      ? "That link signs in a phone, not a computer. On a computer already signed in, open Settings, Account, "
        + "Add a computer… and paste the link it shows."
      : "That link has no setup token. On a computer already signed in, open Settings, Account, Add a "
        + "computer… and copy the whole link."
  }
  if Backend.pairingCode(trimmed) != nil {
    return "That link signs in a phone, not a computer. Use the server’s setup link: on the server, run "
      + "sudo docker compose exec server pocketterm-server setup-link."
  }
  return "That link has no setup token: copy the whole line setup-link printed."
}
#endif
