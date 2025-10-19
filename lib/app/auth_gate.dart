// lib/app/auth_gate.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:untitled/features/auth/presentation/auth_screen.dart';
import 'package:untitled/features/chat/presentation/conversations_screen.dart';
import 'package:untitled/shared/service/user_service.dart';
import 'package:untitled/shared/service/push_service.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = snap.data;
        if (user == null) {
          // показываем реальный экран логина/регистрации
          return const AuthScreen();
        }

        // гарантируем профиль перед входом в приложение
        return FutureBuilder(
          future: ensureUserDoc(user),
          builder: (context, f) {
            if (f.connectionState != ConnectionState.done) {
              return const Scaffold(body: Center(child: CircularProgressIndicator()));
            }
            // Инициализируем пуши
            PushService.instance.init();
            return const ConversationsScreen();
          },
        );
      },
    );
  }
}
