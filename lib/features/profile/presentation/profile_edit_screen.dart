import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _nameC = TextEditingController();
  bool _saving = false;
  String? _photoUrl;

  @override
  void initState() {
    super.initState();
    final u = FirebaseAuth.instance.currentUser!;
    FirebaseFirestore.instance.collection('users').doc(u.uid).get().then((snap) {
      final data = snap.data() ?? {};
      _nameC.text = (data['displayName'] as String?) ?? (u.email ?? '');
      _photoUrl = data['photoUrl'] as String?;
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _nameC.dispose();
    super.dispose();
  }

  Future<void> _pickAndUploadAvatar() async {
    final u = FirebaseAuth.instance.currentUser!;
    final xfile = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (xfile == null) return;

    setState(() => _saving = true);
    try {
      final ref = FirebaseStorage.instance.ref('avatars/${u.uid}.jpg');
      await ref.putFile(File(xfile.path), SettableMetadata(contentType: 'image/jpeg'));
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
        'photoUrl': url,
      }, SetOptions(merge: true));
      setState(() => _photoUrl = url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Аватар обновлён')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final u = FirebaseAuth.instance.currentUser!;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
        'displayName': _nameC.text.trim(),
      }, SetOptions(merge: true));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = _photoUrl != null && _photoUrl!.isNotEmpty
        ? NetworkImage(_photoUrl!)
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundImage: avatar,
                  child: avatar == null ? const Icon(Icons.person, size: 48) : null,
                ),
                Positioned(
                  bottom: -4,
                  right: -4,
                  child: IconButton.filled(
                    onPressed: _saving ? null : _pickAndUploadAvatar,
                    icon: const Icon(Icons.camera_alt),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _nameC,
            decoration: const InputDecoration(
              labelText: 'Имя',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
