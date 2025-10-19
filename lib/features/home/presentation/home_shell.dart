// lib/features/shell/home_shell.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:untitled/features/chat/presentation/conversations_screen.dart';
import 'package:untitled/features/chat/presentation/call_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _callSub;

  @override
  void initState() {
    super.initState();
    final me = FirebaseAuth.instance.currentUser!;
    _callSub = FirebaseFirestore.instance
        .collection('calls')
        .where('calleeUid', isEqualTo: me.uid)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snap) {
      for (final ch in snap.docChanges) {
        if (ch.type == DocumentChangeType.added) {
          final d = ch.doc.data();
          if (d == null) continue;
          final caller = d['callerUid'] as String?;
          final video  = (d['video'] as bool?) ?? true;
          if (caller != null && mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CallScreen.receiver(
                  callId: ch.doc.id,
                  callerUid: caller,
                  video: video,
                ),
              ),
            );
          }
        }
      }
    });
  }

  @override
  void dispose() {
    _callSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    
    return const ConversationsScreen();
  }
}
