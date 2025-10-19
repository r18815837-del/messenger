import 'package:cloud_firestore/cloud_firestore.dart';

enum RoomType { public, dm, group }

RoomType _roomType(String v) {
  switch (v) {
    case 'dm': return RoomType.dm;
    case 'group': return RoomType.group;
    default: return RoomType.public;
  }
}

class Room {
  final String id;
  final RoomType type;
  final String? title;
  final String? photoUrl;
  final String? ownerUid;
  final Map<String, bool> admins;
  final List<String> participants;
  final Map<String, dynamic> participantsInfo;
  final DateTime? updatedAt;

  const Room({
    required this.id,
    required this.type,
    required this.participants,
    this.title,
    this.photoUrl,
    this.ownerUid,
    this.admins = const {},
    this.participantsInfo = const {},
    this.updatedAt,
  });

  factory Room.fromSnap(DocumentSnapshot<Map<String, dynamic>> s) {
    final d = s.data()!;
    return Room(
      id: s.id,
      type: _roomType(d['type'] ?? 'public'),
      title: d['title'],
      photoUrl: d['photoUrl'],
      ownerUid: d['ownerUid'],
      admins: Map<String, bool>.from(d['admins'] ?? const {}),
      participants: List<String>.from(d['participants'] ?? const []),
      participantsInfo: Map<String, dynamic>.from(d['participantsInfo'] ?? const {}),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
    'type': type.name,
    if (title != null) 'title': title,
    if (photoUrl != null) 'photoUrl': photoUrl,
    if (ownerUid != null) 'ownerUid': ownerUid,
    if (admins.isNotEmpty) 'admins': admins,
    'participants': participants,
    if (participantsInfo.isNotEmpty) 'participantsInfo': participantsInfo,
    'updatedAt': FieldValue.serverTimestamp(),
  };
}
