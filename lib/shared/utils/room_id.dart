// lib/shared/utils/room_id.dart

/// Детерминированный roomId для личного чата (A+B в алфавитном порядке).
/// Пример: dm_123_999 и dm_999_123 дадут один и тот же id: dm_123_999
String directRoomId(String a, String b) {
  final ids = [a, b]..sort();
  return 'dm_${ids[0]}_${ids[1]}';
}

/// Простой чек: это ли личный чат
bool isDirectRoom(String roomId) => roomId.startsWith('dm_');

/// Вернуть UID собеседника из roomId вида `dm_<uidA>_<uidB>`.
/// Если не получилось распарсить — вернёт null.
String? otherUidFromRoom(String roomId, String myUid) {
  if (!isDirectRoom(roomId)) return null;
  final parts = roomId.split('_'); // ['dm', uidA, uidB]
  if (parts.length != 3) return null;
  final a = parts[1], b = parts[2];
  if (myUid == a) return b;
  if (myUid == b) return a;
  return null;
}

