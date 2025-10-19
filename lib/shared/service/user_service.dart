// lib/shared/services/user_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Создаёт/обновляет профиль users/{uid} без перезатирания createdAt/имени.
Future<void> ensureUserDoc(User u) async {
  final users = FirebaseFirestore.instance.collection('users');
  final ref = users.doc(u.uid);
  final snap = await ref.get();

  final email = u.email ?? '';
  final defaultName = (u.displayName?.trim().isNotEmpty == true)
      ? u.displayName!
      : (email.isNotEmpty ? email.split('@').first : 'Пользователь');

  // То, что точно обновляем
  final base = <String, dynamic>{
    'uid': u.uid,
    'email': email.isNotEmpty ? email : null,
    'emailLower': email.isNotEmpty ? email.toLowerCase() : null,
    'photoUrl': u.photoURL ?? '',
    'updatedAt': FieldValue.serverTimestamp(),
  }..removeWhere((k, v) => v == null);

  // Если дока ещё нет — добавим createdAt и первоначальное имя
  if (!snap.exists) {
    base['createdAt'] = FieldValue.serverTimestamp();
    base['displayName'] = defaultName;
  } else {
    // Если док есть, но displayName пустой — проставим дефолтный
    final current = snap.data() ?? {};
    final currentName = (current['displayName'] as String?)?.trim() ?? '';
    if (currentName.isEmpty) {
      base['displayName'] = defaultName;
    }
  }

  await ref.set(base, SetOptions(merge: true));
}

/// Удобный хелпер на текущего пользователя (опционально).
Future<void> ensureCurrentUserDoc() async {
  final u = FirebaseAuth.instance.currentUser;
  if (u != null) await ensureUserDoc(u);
}
