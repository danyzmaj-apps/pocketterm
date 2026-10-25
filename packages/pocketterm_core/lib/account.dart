/// Signing a computer in (with its server's setup link; phones sign in
/// with a computer's code) and who is signed in (the avatar).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/ui.dart';

class SignInPage extends StatelessWidget {
  const SignInPage({required this.session, super.key});
  final Session session;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: C.round(18),
              gradient: LinearGradient(
                colors: [Color.lerp(C.bar, C.accent, .2)!, C.bar],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: C.line, width: C.border),
            ),
            child: const PocketTermLogo(size: 52),
          ),
          const SizedBox(height: 18),
          const Text('PocketTerm', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            'Sign in to connect this computer to your phone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.dim),
          ),
          const SizedBox(height: 16),
          Text(
            session.authError ??
                'Open your server\u2019s setup link on this computer. To see it again, run '
                    '`pocketterm-server setup-link` on the server.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: session.authError == null ? C.dim2 : C.error),
          ),
          if (session.retryLink != null) ...[
            const SizedBox(height: 12),
            FilledButton(onPressed: () => unawaited(session.retry()), child: const Text('Try again')),
          ],
          const SizedBox(height: 20),
          TextButton(
            onPressed: () => unawaited(session.disconnect()),
            child: Text(
              'Connected to ${session.backend?.host ?? '?'} · Use a different server',
              style: TextStyle(fontSize: 11, color: C.dim2),
            ),
          ),
        ],
      ),
    ),
  );
}

class Avatar extends StatelessWidget {
  const Avatar({required this.name, this.url, this.size = 24, super.key});
  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [C.accent, Color.lerp(C.accent, C.error, .5)!]),
      ),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(fontSize: size * .45, fontWeight: FontWeight.w700, color: C.onAccent),
      ),
    );
    if (url == null) return letter;
    return ClipOval(
      child: Image.network(url!, width: size, height: size, errorBuilder: (_, _, _) => letter),
    );
  }
}
