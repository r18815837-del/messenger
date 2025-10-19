import 'dart:async'; // ⬅️ NEW
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:untitled/features/chat/presentation/chat_screen.dart';
import 'package:untitled/shared/utils/room_id.dart';
import 'package:untitled/features/profile/presentation/profile_edit_screen.dart';
import 'package:untitled/core/widgets/user_avatar.dart';
import 'package:untitled/core/widgets/unread_dot.dart';
import 'package:untitled/features/chat/presentation/create_group_screen.dart';
import 'package:untitled/features/chat/presentation/call_screen.dart'; 

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _callSub; 

  @override
  void initState() {
    super.initState();

    )
    final me = FirebaseAuth.instance.currentUser;
    if (me != null) {
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
            final video = (d['video'] as bool?) ?? true;
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
  }

  @override
  void dispose() {
    _callSub?.cancel();
    super.dispose();
  }
  Future<void> _startDmByEmail(BuildContext context) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final me = FirebaseAuth.instance.currentUser!;
    final c = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новый личный чат'),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email пользователя',
            hintText: 'user@example.com',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Начать')),
        ],
      ),
    ) ?? false;

    if (!ok) return;

    final raw = c.text.trim();
    final emailLower = raw.toLowerCase();

    if (raw.isEmpty || !raw.contains('@')) {
      messenger.showSnackBar(const SnackBar(content: Text('Введите корректный email')));
      return;
    }

    try {
      
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where(Filter.or(
        Filter('emailLower', isEqualTo: emailLower),
        Filter('email', isEqualTo: raw),
      ))
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Пользователь не найден.\n'
                'Убедитесь, что он хотя бы раз входил в приложение (тогда его профиль создастся в Firestore).',
          ),
          duration: Duration(seconds: 4),
        ));
        return;
      }

      final other = q.docs.first.data();
      final otherUid = (other['uid'] as String?) ?? '';
      if (otherUid.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('Некорректный профиль пользователя')));
        return;
      }
      if (otherUid == me.uid) {
        messenger.showSnackBar(const SnackBar(content: Text('Нельзя начать чат с собой')));
        return;
      }

      final roomId = directRoomId(me.uid, otherUid);

      // создаём/обновляем комнату DM
      await FirebaseFirestore.instance.collection('rooms').doc(roomId).set({
        'roomId': roomId,
        'type': 'dm',
        'participants': [me.uid, otherUid],
        'participantsInfo': {
          me.uid: {
            'email': me.email,
            'displayName': me.displayName ?? (me.email ?? '').split('@').first,
            'photoUrl': me.photoURL ?? '',
          },
          otherUid: {
            'email': other['email'],
            'displayName': (other['displayName'] as String?) ?? (other['email'] as String?)?.split('@').first ?? 'Пользователь',
            'photoUrl': (other['photoUrl'] as String?) ?? '',
          },
        },
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      nav.push(MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }


  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser!;
    final roomsQuery = FirebaseFirestore.instance
        .collection('rooms')
        .where(
      Filter.or(
        Filter('type', isEqualTo: 'public'),
        Filter('participants', arrayContains: me.uid),
      ),
    )
        .orderBy('updatedAt', descending: true)
        .limit(100);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'Профиль',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileEditScreen()),
            ),
          ),
          
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: 'Новый личный чат',
            onPressed: () => _startDmByEmail(context),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: roomsQuery.snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final rooms = snap.data?.docs ?? [];
          if (rooms.isEmpty) {
            return const Center(child: Text('Пока нет чатов'));
          }

          return ListView.separated(
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = rooms[i];
              final data = r.data();
              final roomId = r.id;
              final type = (data['type'] as String?) ?? 'dm';
              final isDm = type == 'dm';
              final last = (data['lastMessage'] as String?) ?? '';

              if (!isDm) {
                
                return ListTile(
                  leading: const UserAvatar(title: 'P'),
                  title: const Text('Общий чат'),
                  subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: UnreadDot(roomId: roomId),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)),
                  ),
                );
              }

             
              final other = otherUidFromRoom(roomId, me.uid);
              if (other == null) {
                return ListTile(
                  leading: const UserAvatar(title: '?'),
                  title: Text(roomId),
                  subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: UnreadDot(roomId: roomId),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)),
                  ),
                );
              }

              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance.collection('users').doc(other).snapshots(),
                builder: (context, userSnap) {
                  final u = userSnap.data?.data();
                  final name = (u?['displayName'] as String?) ??
                      (u?['email'] as String?) ??
                      'Пользователь';
                  final photo = (u?['photoUrl'] as String?) ?? '';
                  final typing = ((data['typing'] ?? {}) as Map<String, dynamic>)[other] == true;

                  return ListTile(
                    leading: UserAvatar(photoUrl: photo, title: name),
                    title: Text(name),
                    subtitle: Text(
                      typing ? 'печатает…' : last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: typing ? const TextStyle(fontStyle: FontStyle.italic) : null,
                    ),
                    trailing: UnreadDot(roomId: roomId),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
     
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'fab_group',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
              );
            },
            icon: const Icon(Icons.group_add),
            label: const Text('Группа'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'fab_dm',
            onPressed: () => _startDmByEmail(context),
            icon: const Icon(Icons.chat),
            label: const Text('Новый чат'),
          ),
        ],
      ),
    );
  }
}
