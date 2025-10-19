// lib/features/chat/presentation/group_info_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../chat/models/room.dart';
import '../../../shared/service/room_service.dart';

class GroupInfoScreen extends StatelessWidget {
  final Room room;
  const GroupInfoScreen({super.key, required this.room});

  @override
  Widget build(BuildContext context) {
    final me = FirebaseAuth.instance.currentUser!.uid;
    final isAdmin = room.admins[me] == true;
    final roomService = RoomService(FirebaseFirestore.instance, FirebaseAuth.instance);

    return Scaffold(
      appBar: AppBar(title: const Text('Информация о группе')),
      body: ListView(
        children: [
          ListTile(
            leading: UserAvatar(
              photoUrl: room.photoUrl,
              title: room.title ?? 'Группа',
              radius: 24,
            ),
            title: Text(room.title ?? 'Группа'),
            subtitle: Text('${room.participants.length} участник(ов)'),
          ),
          const Divider(),

          if (isAdmin)
            ListTile(
              leading: const Icon(Icons.person_add),
              title: const Text('Добавить участников'),
              onTap: () async {
              
              },
            ),

          
          for (final uid in room.participants)
            ListTile(
              leading: UserAvatar(
                photoUrl: room.participantsInfo[uid]?['photoUrl'] as String?,
                title: (room.participantsInfo[uid]?['displayName'] ?? uid).toString(),
                radius: 18,
              ),
              title: Text(
                (room.participantsInfo[uid]?['displayName'] ?? uid).toString(),
              ),
              trailing: isAdmin && uid != room.ownerUid
                  ? PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'admin_on') {
                    await roomService.setAdmin(room.id, uid, true);
                  } else if (v == 'admin_off') {
                    await roomService.setAdmin(room.id, uid, false);
                  } else if (v == 'remove') {
                    await roomService.removeParticipant(room.id, uid);
                  }
                },
                itemBuilder: (_) => [
                  if (room.admins[uid] == true)
                    const PopupMenuItem(value: 'admin_off', child: Text('Снять админа'))
                  else
                    const PopupMenuItem(value: 'admin_on', child: Text('Назначить админом')),
                  const PopupMenuItem(value: 'remove', child: Text('Удалить из группы')),
                ],
              )
                  : null,
            ),

          const Divider(),

          
          ListTile(
            leading: const Icon(Icons.exit_to_app),
            title: const Text('Покинуть группу'),
            onTap: () async {
              
              final nav = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              try {
                await roomService.leaveGroup(room.id);
                if (!context.mounted) return;
                nav.popUntil((r) => r.isFirst);
              } catch (e) {
                if (!context.mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text('Невозможно выйти: $e')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
