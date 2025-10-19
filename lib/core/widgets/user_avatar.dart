// lib/core/widgets/user_avatar.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UserAvatar extends StatelessWidget {
  /// Вариант 1: грузим профиль по uid из Firestore (users/{uid})
  final String? uid;

  /// Вариант 2: рисуем напрямую по ссылке на фото
  final String? photoUrl;

  /// Имя/подпись для инициалов (если нет фото)
  final String? name;

  /// alias к name — если где-то уже используется title
  final String? title;

  /// Размер аватарки (диаметр). Если указан radius — он приоритетнее.
  final double size;

  /// Alias как у CircleAvatar: radius = size / 2
  final double? radius;

  final VoidCallback? onTap;

  const UserAvatar({
    super.key,
    this.uid,
    this.photoUrl,
    this.name,
    this.title,
    this.size = 36,
    this.radius,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveSize = radius != null ? radius! * 2 : size;

    // Если передан uid — читаем профиль из Firestore
    if (uid != null) {
      final ref = FirebaseFirestore.instance.collection('users').doc(uid);
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: ref.snapshots(),
        builder: (context, snap) {
          final data = snap.data?.data() ?? {};
          final url = (data['photoUrl'] as String?) ?? '';
          final display =
              (data['displayName'] as String?) ??
                  (data['email'] as String?) ??
                  '';
          return _buildCircle(url: url, label: display, size: effectiveSize);
        },
      );
    }

    // Иначе рисуем по переданным параметрам
    return _buildCircle(
      url: photoUrl ?? '',
      label: name ?? title ?? '',
      size: effectiveSize,
    );
  }

  Widget _buildCircle({
    required String url,
    required String label,
    required double size,
  }) {
    final initial = _initialFrom(label);
    final avatar = CircleAvatar(
      radius: size / 2,
      backgroundImage: url.isNotEmpty ? NetworkImage(url) : null,
      child: url.isEmpty
          ? Text(initial, style: TextStyle(fontSize: size * 0.45))
          : null,
    );

    return onTap != null
        ? InkWell(onTap: onTap, customBorder: const CircleBorder(), child: avatar)
        : avatar;
  }

  String _initialFrom(String text) {
    final t = text.trim();
    if (t.isEmpty) return '?';
    return t[0].toUpperCase();
  }
}
