// lib/features/chat/presentation/create_group_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'chat_screen.dart';
import '../../../shared/service/room_service.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _title = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final roomService = RoomService(FirebaseFirestore.instance, FirebaseAuth.instance);

    return Scaffold(
      appBar: AppBar(title: const Text('Новая группа')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Название группы'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                final nav = Navigator.of(context);                // <— сохраняем заранее
                final messenger = ScaffoldMessenger.of(context);  // <— и это тоже
                final title = _title.text.trim();
                if (title.isEmpty) {
                  messenger.showSnackBar(const SnackBar(content: Text('Введите название')));
                  return;
                }
                setState(() => _saving = true);
                try {
                  final id = await roomService.createGroup(title: title);
                  nav.pushReplacement(MaterialPageRoute(builder: (_) => ChatScreen(roomId: id)));
                } catch (e) {
                  messenger.showSnackBar(SnackBar(content: Text('Ошибка: $e')));
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
              child: _saving ? const CircularProgressIndicator() : const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }
}
