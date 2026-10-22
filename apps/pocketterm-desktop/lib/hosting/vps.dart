import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/backend.dart';

/// The name a VPS's server answers at, from what the person typed: a
/// domain as it is, an IPv4 address as its sslip.io name
/// (`203.0.113.7` → `203-0-113-7.sslip.io`, a name that resolves to that
/// address), so Caddy can get a certificate for it. Either [domain] or
/// [error] is set.
@immutable
class ServerAddress {
  const ServerAddress._(this.domain, this.error, [this.host, this.user]);

  factory ServerAddress.parse(String typed) {
    var s = typed.trim().toLowerCase();
    s = s.replaceFirst(RegExp('^[a-z]+://'), '');
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    // user@host, as an SSH line has it ("ssh ubuntu@203.0.113.7").
    final at = s.lastIndexOf('@');
    final user = at < 0 ? null : s.substring(0, at).split(RegExp(r'\s+')).last;
    s = s.substring(at + 1);
    while (s.endsWith('.')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return const ServerAddress._(null, 'Enter your server’s IP address or domain name.');
    final ip = InternetAddress.tryParse(s.startsWith('[') && s.endsWith(']') ? s.substring(1, s.length - 1) : s);
    if (ip?.type == InternetAddressType.IPv6 || (ip == null && s.startsWith('['))) {
      return const ServerAddress._(
        null,
        'Use the server’s IPv4 address (like 203.0.113.7) or a domain name. An IPv6-only server doesn’t work: '
        'Docker gets the server from GitHub’s registry (ghcr.io), which has no IPv6, and many phone networks reach '
        'only IPv4. Most providers add an IPv4 address for a small fee.',
      );
    }
    if (ip != null) {
      if (ip.isLoopback || ip.isLinkLocal || _isPrivate(ip.rawAddress)) {
        return const ServerAddress._(
          null,
          'That’s a private address. Use the public IP address your VPS provider shows for the server.',
        );
      }
      return ServerAddress._('${s.replaceAll('.', '-')}.sslip.io', null, s, user);
    }
    if (s.contains(':')) return const ServerAddress._(null, 'Leave out the port: the server answers on 443.');
    final label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
    final labels = s.split('.');
    if (labels.length < 2 || !labels.every(label.hasMatch) || RegExp(r'^\d+$').hasMatch(labels.last)) {
      return const ServerAddress._(null, 'That isn’t an IP address or a domain name, like pocketterm.example.com.');
    }
    return ServerAddress._(s, null, s, user);
  }

  final String? domain;

  /// Why what was typed can't be used, for the person.
  final String? error;

  /// What was typed, as SSH reaches the server: its IP address or domain,
  /// and the user, if one was typed with it.
  final String? host;
  final String? user;

  /// How to sign in to the server from here.
  String? get ssh => host == null ? null : 'ssh ${user == null || user!.isEmpty ? 'root' : user}@$host';

  /// 10/8, 172.16/12, 192.168/16, 100.64/10 (carrier-grade NAT, Tailscale).
  static bool _isPrivate(List<int> b) =>
      b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
      b[0] == 0;
}

/// One command to run on the VPS, and what it does.
typedef VpsCommand = ({String title, String command});

/// The compose file the commands fetch: the repository's at release tag v[version], this app's version, so the
/// VPS runs what this release shipped (the file pins the image to the same version).
String composeUrl(String version) =>
    'https://raw.githubusercontent.com/danyzmaj-apps/pocketterm/v$version/apps/pocketterm-server/docker-compose.yml';

/// What to run on a fresh VPS for a server at [domain], with this app's [version], in order: Docker,
/// the compose file, start it, its setup link. Each one stands alone (it
/// changes to ~/pocketterm itself), so a new SSH session can pick up where
/// the last one left off. docs/SELF_HOSTING.md shows the same commands.
List<VpsCommand> vpsCommands(String domain, String version) => [
  (title: 'Install Docker', command: 'curl -fsSL https://get.docker.com | sudo sh'),
  (title: 'Get the server', command: 'mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO ${composeUrl(version)}'),
  (title: 'Start it', command: 'cd ~/pocketterm && echo "DOMAIN=$domain" > .env && sudo docker compose up -d'),
  (
    title: 'Print its setup link',
    command: 'cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link',
  ),
];

/// What the setup looks at while a VPS is being set up: the name resolves,
/// HTTPS answers on it (Caddy got its certificate), the server is healthy.
/// Tests hand in their own.
class ServerChecks {
  const ServerChecks();

  /// [domain] resolves to an IPv4 address (an A record: an IPv6-only name
  /// leaves out the phone networks that reach only IPv4).
  Future<bool> resolves(String domain) async {
    try {
      final found = await InternetAddress.lookup(
        domain,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 8));
      return found.isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// A TLS handshake with [domain] on 443 succeeds: a valid certificate.
  Future<bool> https(String domain) async {
    try {
      final socket = await SecureSocket.connect(domain, 443, timeout: const Duration(seconds: 8));
      socket.destroy();
      return true;
    } on Object {
      return false;
    }
  }

  /// The server at [domain]: `https://<domain>`.
  Backend backendFor(String domain) => Backend(url: 'https://$domain');

  /// GET /v1/health: `error` is null when it's a PocketTerm server this app
  /// speaks to, else what's wrong; `clockOffset`, how far its clock is from
  /// this computer's ([Backend.clockWarning]).
  Future<ServerHealth> health(String domain) => answers(backendFor(domain));

  /// [backend]'s GET /v1/health, as [health] (a pasted setup link's server).
  Future<ServerHealth> answers(Backend backend) => backend.health();
}

/// A server's answer to GET /v1/health ([Backend.health]).
typedef ServerHealth = ({String? error, Duration? clockOffset});
