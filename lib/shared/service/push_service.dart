// lib/shared/services/push_service.dart
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  Future<void> init() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;

    // iOS/web: запрос разрешения
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true, badge: true, sound: true,
    );
    debugPrint('[PUSH] permission: ${settings.authorizationStatus}');

    // Android 13+: пользователю тоже надо выдать системное разрешение (у тебя уже спрашивается системой)
    // Получаем токен
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) {
      await _saveToken(u.uid, token);
    }

    // Обновление токена
    FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null && t.isNotEmpty) {
        _saveToken(user.uid, t);
      }
    });
  }

  Future<void> _saveToken(String uid, String token) async {
    // Храним токены как документы в сабколлекции: users/{uid}/tokens/{token}
    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('tokens')
        .doc(token)
        .set({
      'platform': Platform.isAndroid ? 'android' : Platform.isIOS ? 'ios' : 'other',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    debugPrint('[PUSH] saved token: $token');
  }
}
