import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/ui.dart';

/// A setup link from outside the app to another server
/// ([Session.linkToConfirm]): nothing happens until the person says yes.
/// Anyone can send such a link, and this device's sessions would then go
/// through that server.
class ConfirmLink extends StatelessWidget {
  const ConfirmLink({required this.session, required this.link, super.key});
  final Session session;
  final Uri link;

  @override
  Widget build(BuildContext context) {
    final host = Backend.fromLink(link)?.host ?? '?';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.warn),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Connect to $host?', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'A link asks to connect PocketTerm to this server. Only connect if you opened it yourself, from your own '
            'computer or server: your sessions and the images you send go through it.',
            style: TextStyle(color: C.dim, height: 1.4),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => unawaited(session.answerLink(connect: false)), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => unawaited(session.answerLink(connect: true)), child: const Text('Connect')),
            ],
          ),
        ],
      ),
    );
  }
}
