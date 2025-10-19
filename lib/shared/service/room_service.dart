// lib/shared/services/room_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RoomService {
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  RoomService(this._db, this._auth);
  Future<String> createGroup({required String title}) async {
    final me = _auth.currentUser!;
    final ref = _db.collection('rooms').doc();
    await ref.set({
      'type': 'group',
      'title': title,
      // ← УДАЛИЛИ: if (photoUrl != null) 'photoUrl': photoUrl,
      'ownerUid': me.uid,
      'admins': {me.uid: true},
      'participants': [me.uid],
      'participantsInfo': {
        me.uid: {
          'displayName': me.displayName ?? me.email,
          'photoUrl': me.photoURL,
        }
      },
      'updatedAt': FieldValue.serverTimestamp(),
      'typing': {},
    });
    await ref.collection('members').doc(me.uid).set({
      'lastReadAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  // ↓↓↓ делаем тип публичным (был _UserLite)
  Future<void> addParticipants(String roomId, List<UserLite> users) async {
    final ref = _db.collection('rooms').doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final d = snap.data()!;
      final admins = Map<String, dynamic>.from(d['admins'] ?? {});
      if (admins[_auth.currentUser!.uid] != true) {
        throw 'not_admin';
      }

      final parts = List<String>.from(d['participants'] ?? []);
      final info = Map<String, dynamic>.from(d['participantsInfo'] ?? {});
      for (final u in users) {
        if (!parts.contains(u.uid)) {
          parts.add(u.uid);
          info[u.uid] = {'displayName': u.displayName, 'photoUrl': u.photoUrl};
        }
      }
      tx.update(ref, {
        'participants': parts,
        'participantsInfo': info,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    for (final u in users) {
      await ref.collection('members').doc(u.uid).set({
        'lastReadAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  Future<void> removeParticipant(String roomId, String targetUid) async {
    final ref = _db.collection('rooms').doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final d = snap.data()!;
      final admins = Map<String, dynamic>.from(d['admins'] ?? {});
      if (admins[_auth.currentUser!.uid] != true) {
        throw 'not_admin';
      }

      final ownerUid = d['ownerUid'] as String?;
      if (targetUid == ownerUid) {
        throw 'cannot_remove_owner';
      }

      final parts = List<String>.from(d['participants'] ?? []);
      final info = Map<String, dynamic>.from(d['participantsInfo'] ?? {});
      parts.remove(targetUid);
      info.remove(targetUid);

      final newAdmins = Map<String, dynamic>.from(admins)..remove(targetUid);

      tx.update(ref, {
        'participants': parts,
        'participantsInfo': info,
        'admins': newAdmins,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await ref.collection('members').doc(targetUid).delete();
  }

  Future<void> setAdmin(String roomId, String targetUid, bool isAdmin) async {
    final ref = _db.collection('rooms').doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final d = snap.data()!;
      final admins = Map<String, dynamic>.from(d['admins'] ?? {});
      if (admins[_auth.currentUser!.uid] != true) {
        throw 'not_admin';
      }

      final ownerUid = d['ownerUid'] as String?;
      if (targetUid == ownerUid) {
        return; // владелец всегда админ
      }

      final newAdmins = Map<String, dynamic>.from(admins);
      if (isAdmin) {
        newAdmins[targetUid] = true;
      } else {
        newAdmins.remove(targetUid);
      }

      tx.update(ref, {'admins': newAdmins, 'updatedAt': FieldValue.serverTimestamp()});
    });
  }

  Future<void> leaveGroup(String roomId) async {
    final me = _auth.currentUser!.uid;
    final ref = _db.collection('rooms').doc(roomId);
    await _db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final d = snap.data()!;
      final ownerUid = d['ownerUid'] as String?;
      if (me == ownerUid) {
        throw 'owner_cannot_leave';
      }

      final parts = List<String>.from(d['participants'] ?? [])..remove(me);
      final admins = Map<String, dynamic>.from(d['admins'] ?? {})..remove(me);

      tx.update(ref, {
        'participants': parts,
        'admins': admins,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await ref.collection('members').doc(me).delete();
  }
}

// Публичный легковесный профиль (был _UserLite)
class UserLite {
  final String uid;
  final String displayName;
  final String? photoUrl;
  const UserLite({required this.uid, required this.displayName, this.photoUrl});
}
