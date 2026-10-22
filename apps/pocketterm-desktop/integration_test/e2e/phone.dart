import 'dart:async';
import 'dart:io';

import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';

/// A phone made of the phone app's own client code (the server client and
/// TerminalRemote from pocketterm_core), signed in with a pairing link as a
/// scan would: for the desktop-only run (`--no-phone`), so every scenario's
/// desktop side is still exercised without the Simulator. It doesn't drive
/// or replace the phone app; the phone's Maestro flows do that.
class StandInPhone {
  StandInPhone._(this.server, this.remote, this.computer);

  /// Signs in with pairing [link] (its code, and the computer's key in it).
  static Future<StandInPhone> pair(Uri link, Directory support) async {
    final backend = Backend.fromLink(link)!;
    final code = Backend.pairingCode(link)!;
    final computer = Backend.computerKey(link)!;
    final server = PocketTermServerClient(backend, tokens: MemoryDeviceTokens());
    await server.redeemCode(code, label: 'E2E stand-in phone', platform: 'ios');
    final remote = TerminalRemote(server, support, desktopId: computer.desktop, key: computer.key)..attach();
    return StandInPhone._(server, remote, computer);
  }

  final PocketTermServerClient server;
  final TerminalRemote remote;
  final ComputerKey computer;

  /// Signs out on the server, as the phone's Sign out does.
  Future<void> signOut() async {
    remote
      ..detach()
      ..dispose();
    await server.leave();
    server.close();
  }

  void dispose() {
    remote
      ..detach()
      ..dispose();
    server.close();
  }
}
