/// Signing in and who is signed in: the same on the Mac and the iPhone.
library;

import 'dart:async';

import 'package:dzep_core/logo.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/material.dart';

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
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF2A3150), Color(0xFF141722)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: const Color(0xFF3A4160)),
            ),
            child: const DzepLogo(size: 52),
          ),
          const SizedBox(height: 18),
          const Text('Džep', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Sign in to sync your ideas across your Mac and phone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.dim),
          ),
          const SizedBox(height: 26),
          GithubButton(onPressed: () => unawaited(session.signIn())),
          const SizedBox(height: 16),
          Text(
            session.authError ?? 'Required. Opens your browser once; you stay signed in after that.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: session.authError == null ? C.dim2 : const Color(0xFFFCA5A5)),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: () => unawaited(session.disconnect()),
            child: Text(
              'Syncing through ${session.backend?.host ?? '?'} · Use a different project',
              style: const TextStyle(fontSize: 11, color: C.dim2),
            ),
          ),
        ],
      ),
    ),
  );
}

class GithubButton extends StatelessWidget {
  const GithubButton({required this.onPressed, this.compact = false, super.key});
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: const Color(0xFFF0F1F4),
      foregroundColor: const Color(0xFF111111),
      minimumSize: compact ? null : const Size.fromHeight(44),
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 10 : 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: compact ? 13 : 14),
    ),
    child: const Text('Continue with GitHub'),
  );
}

class Avatar extends StatelessWidget {
  const Avatar({required this.url, required this.name, this.size = 24, super.key});
  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [Color(0xFF7C9CFF), Color(0xFFC084FC)]),
      ),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(fontSize: size * .45, fontWeight: FontWeight.w700, color: const Color(0xFF111111)),
      ),
    );
    if (url == null) return letter;
    return ClipOval(
      child: Image.network(url!, width: size, height: size, errorBuilder: (_, _, _) => letter),
    );
  }
}
