// lib/features/home/presentation/home_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:untitled/features/chat/presentation/chat_screen.dart';
import 'package:untitled/shared/utils/room_id.dart';



class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _startDmByEmail(BuildContext context) async {
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
    );
    if (ok != true) return;

    final email = c.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Введите корректный email')),
        );
      }
      return;
    }
    if (email.toLowerCase() == (me.email ?? '').toLowerCase()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Нельзя писать самому себе')),
        );
      }
      return;
    }

    try {
   
      final q = await FirebaseFirestore.instance
          .collection('users')
          .where('emailLower', isEqualTo: email.toLowerCase())
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Пользователь не найден')),
          );
        }
        return;
      }

      final other = q.docs.first.data();
      final otherUid = other['uid'] as String;
      final otherEmail = (other['email'] as String?) ?? email;

     
      final roomId = directRoomId(me.uid, otherUid);

     
      await FirebaseFirestore.instance.collection('rooms').doc(roomId).set({
        'roomId': roomId,
        'type': 'dm',
        'participants': [me.uid, otherUid],
        'participantsInfo': {
          me.uid: {'email': me.email},
          otherUid: {'email': otherEmail},
        },
        'updatedAt': FieldValue.serverTimestamp(),
        'lastMessage': '',
      }, SetOptions(merge: true));

      
      if (context.mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser!;

   
    final roomsStream = FirebaseFirestore.instance
        .collection('rooms')
        .where('participants', arrayContains: me.uid)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
            tooltip: 'Public чат',
            icon: const Icon(Icons.public),
            onPressed: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatScreen(roomId: 'public')));
            },
          ),
          IconButton(
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout),
            onPressed: () => FirebaseAuth.instance.signOut(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Новый личный чат',
        onPressed: () => _startDmByEmail(context),
        child: const Icon(Icons.message),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: roomsStream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Ошибка: ${snap.error}'));
          }
          final docs = snap.data?.docs ?? [];

        
          docs.sort((a, b) {
            final at = (a.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
            final bt = (b.data()['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);
            return bt.compareTo(at);
          });

          if (docs.isEmpty) {
            return const Center(child: Text('Пока нет диалогов. Нажмите кнопку сообщения, чтобы начать.'));
          }

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_,__) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = docs[i].data();
              final roomId = (d['roomId'] as String?) ?? '';
              final type = (d['type'] as String?) ?? 'dm';
              final lastMessage = (d['lastMessage'] as String?) ?? '';
              final updatedAt = (d['updatedAt'] as Timestamp?)?.toDate();

              String title;
              if (roomId == 'public' || type == 'public') {
                title = 'Public чат';
              } else {
                
                title = _titleForDm(d, me.uid);
              }

              return ListTile(
                leading: CircleAvatar(child: Text(title.isNotEmpty ? title[0].toUpperCase() : '?')),
                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(lastMessage, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: updatedAt == null
                    ? null
                    : Text(_humanTime(updatedAt), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)));
                },
              );
            },
          );
        },
      ),
    );
  }

  String _titleForDm(Map<String, dynamic> room, String myUid) {
    final info = (room['participantsInfo'] as Map?) ?? {};
    for (final entry in info.entries) {
      if (entry.key != myUid) {
        final m = entry.value as Map?;
        final email = m?['email'] as String?;
        if (email != null && email.isNotEmpty) return email;
      }
    }
    return 'Личный чат';
  }

  String _humanTime(DateTime dt) {
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    return '$dd.$mm';
  }
}
