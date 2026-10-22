import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// How long a phone's code works (POST /v1/pair).
const pairingLifetime = Duration(minutes: 10);

/// A QR the phone opens in PocketTerm (its Scan button, or the iPhone's Camera):
/// the server's address, a one-time sign-in code and this computer's channel
/// key (lib/e2e.dart), so the phone is set up, signed in and able to read this
/// computer by the scan alone (a phone has no other way in). Anyone who scans
/// it gets into the account and can read this computer's sessions, so it is
/// made fresh when shown, its sign-in works once, and it hides itself when it
/// runs out; the key stays good until Reset key (Settings → Phone).
class PairingQr extends StatefulWidget {
  const PairingQr({required this.session, super.key});
  final Session session;

  @override
  State<PairingQr> createState() => _PairingQrState();
}

class _PairingQrState extends State<PairingQr> {
  late Future<Uri> _link = widget.session.pairingLink();
  Timer? _expiry;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    _startExpiry();
  }

  void _startExpiry() {
    _expiry?.cancel();
    _expiry = Timer(pairingLifetime, () {
      if (mounted) setState(() => _expired = true);
    });
  }

  void _renew() => setState(() {
    _link = widget.session.pairingLink();
    _expired = false;
    _startExpiry();
  });

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 210,
        height: 210,
        child: _expired
            ? _placeholder('This code ran out.', action: 'Make a new one')
            : FutureBuilder<Uri>(
                future: _link,
                builder: (context, snap) {
                  if (snap.error case final e?) {
                    return _placeholder(
                      e is PairingException ? e.message : "Couldn't make a code: $e",
                      action: 'Retry',
                    );
                  }
                  final link = snap.data;
                  if (link == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                  return Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                    child: QrImageView(data: link.toString(), padding: EdgeInsets.zero),
                  );
                },
              ),
      ),
      const SizedBox(height: 14),
      const Text(
        'On your phone: install PocketTerm and tap Scan the code from your computer '
        '(on iPhone the Camera works too). It connects and signs in; nothing to type.',
        textAlign: TextAlign.center,
        style: TextStyle(color: C.dim, height: 1.45),
      ),
      const SizedBox(height: 8),
      const Text(
        "This code is a secret. Anyone who scans it can read this computer's sessions. "
        'The sign-in works once, for 10 minutes; the key in it works until you reset it in Settings.',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
      ),
    ],
  );

  Widget _placeholder(String text, {required String action}) => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: C.dim),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: _renew, child: Text(action)),
    ],
  );
}

/// Settings → Phone → "Add a phone…".
Future<void> showPairingQr(BuildContext context, Session session) => showDialog<void>(
  context: context,
  builder: (dialog) => AlertDialog(
    backgroundColor: C.bar,
    title: const Text('Set up your phone'),
    content: SizedBox(width: 320, child: PairingQr(session: session)),
    actions: [TextButton(onPressed: () => Navigator.of(dialog).pop(), child: const Text('Done'))],
  ),
);
