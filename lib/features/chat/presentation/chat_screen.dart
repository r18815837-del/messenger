// lib/features/chat/presentation/chat_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import 'dart:async';
import 'package:mime/mime.dart';
import 'package:untitled/features/chat/presentation/call_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:any_link_preview/any_link_preview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:untitled/core/widgets/user_avatar.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:untitled/shared/utils/room_id.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:untitled/features/chat/presentation/fullscreen_image_screen.dart';

class ChatScreen extends StatefulWidget {
  final String roomId; // 'public' или dm_<a>_<b>
  const ChatScreen({super.key, this.roomId = 'public'});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}
class _ChatScreenState extends State<ChatScreen> {

  final TextEditingController _c = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  final Map<String, GlobalKey> _msgKeys = {};
  String? _highlightId;

  bool _showEmoji = false;
  bool _sending = false;
  int _limit = 50;
  Timer? _typingTimer;
  bool _showJumpToBottom = false;

  
  bool _searchMode = false;
  String _query = '';

  
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recMs = 0;
  Timer? _recTimer;
  String? _recPath;

  
  final Map<String, AudioPlayer> _audioPlayers = {};
  final Map<String, double> _audioSpeed = {}; 
  final Set<String> _audioInited = {};
  String? _playingId;

  
  UploadTask? _currentUpload;
  double? _uploadProgress;

  
  // ignore: prefer_final_fields
  String _roomType = 'public';
 
  Map<String, dynamic> _participantsInfo = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _roomSub;

  
  bool _offline = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;

 
  late final DocumentReference<Map<String, dynamic>> _roomRef;
  late final DocumentReference<Map<String, dynamic>> _myMemberRef;

  
  String _fmtMs(int ms) {
    final s = (ms ~/ 1000) % 60;
    final m = (ms ~/ 1000) ~/ 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  
  CollectionReference<Map<String, dynamic>> get _messagesCol =>
      FirebaseFirestore.instance
          .collection('rooms')
          .doc(widget.roomId)
          .collection('messages');

  @override
  void initState() {
    super.initState();
    _initAudioSession();
    final me = FirebaseAuth.instance.currentUser!;
    _roomRef = FirebaseFirestore.instance.collection('rooms').doc(widget.roomId);
    _myMemberRef = _roomRef.collection('members').doc(me.uid);

    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      setState(() => _offline = !hasConnection);
      _roomSub = _roomRef.snapshots().listen((snap) {
        final d = snap.data();
        if (d == null) return;
        setState(() {
          _roomType = (d['type'] as String?) ?? 'public';
          _participantsInfo =
              (d['participantsInfo'] as Map?)?.cast<String, dynamic>() ?? {};
        });
      });


    });


    Connectivity().checkConnectivity().then((results) {
      if (!mounted) return;
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      setState(() => _offline = !hasConnection);
    });


    _markSeen();              
    _scroll.addListener(_onScroll);
    _initAudioSession();

  }
  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0, // при reverse: true «низ» — это 0
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _cancelCurrentUpload() {
    final t = _currentUpload;
    if (t != null) {
      try { t.cancel(); } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _currentUpload = null;
      _uploadProgress = null;
      _sending = false;
    });
  }
  void _onScroll() {
    if (!_scroll.hasClients) return;

    // при reverse:true «верх истории» = maxScrollExtent
    final atTopPart = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 200;
    if (atTopPart) {
      setState(() => _limit += 50);
    }

    
    final show = _scroll.position.pixels > 200;
    if (show != _showJumpToBottom) {
      setState(() => _showJumpToBottom = show);
    }
  }


  Future<void> _markSeen() async {
    try {
      await _myMemberRef.set({
        'lastReadAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[markSeen] $e');
    }
  }

  String? _replyToId;
  Map<String, dynamic>? _replyToData;

  @override
  void dispose() {
    
    _typingTimer?.cancel();
    _roomSub?.cancel();
    _connSub?.cancel();
    _recTimer?.cancel(); 

    
    if (_isRecording) {
      unawaited(_recorder.stop());
    }
    _recorder.dispose();
    if (_recPath != null) {
      try { File(_recPath!).deleteSync(); } catch (_) {}
    }

   
    try { _currentUpload?.cancel(); } catch (_) {}
    _currentUpload = null;
    _uploadProgress = null;

    
    final me = FirebaseAuth.instance.currentUser;
    if (me != null) {
      _roomRef.set({'typing': {me.uid: false}}, SetOptions(merge: true));
    }



   
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _c.dispose();
    _inputFocus.dispose();
    for (final p in _audioPlayers.values) {
      try {
        p.stop();
        p.dispose();
      } catch (_) {}
    }
    _audioPlayers.clear();

    super.dispose();
  }
  String? _extractFirstUrl(String text) {
    final re = RegExp(
      r'(https?://[^\s<>")\]\}]+)',
      caseSensitive: false,
    );
    final m = re.firstMatch(text);
    return m?.group(0);
  }


  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть файл')),
      );
    }
  }

  void _jumpToMessage(String msgId) {
    final key = _msgKeys[msgId];
    if (key?.currentContext != null) {
      setState(() => _highlightId = msgId);

      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.5, // центрируем
      );

      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() => _highlightId = null);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сообщение выше по истории, прокрутите вверх'),
        ),
      );
    }
  }

  void _notifyTyping() {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;

    
    _roomRef.set({
      'typing': {me.uid: true},
    }, SetOptions(merge: true));

   
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      _roomRef.set({
        'typing': {me.uid: false},
      }, SetOptions(merge: true));
    });
  }
  Future<void> _sendText() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final messenger = ScaffoldMessenger.of(context);

    setState(() => _sending = true);
    try {
      final data = <String, dynamic>{
        'type': 'text',
        'text': text,
        'uid': user.uid,
        'email': user.email,
        'timestamp': FieldValue.serverTimestamp(),
        'clientTs': DateTime.now().millisecondsSinceEpoch,
        'edited': false,
      };
      if (_replyToId != null) {
        data['replyTo'] = {
          'id': _replyToId,
          'text': (_replyToData?['text'] as String?) ?? '',
        };
      }

      await _messagesCol.add(data);

      await FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).set({
        'roomId': widget.roomId,
        'type': isDirectRoom(widget.roomId) ? 'dm' : _roomType,
        'lastMessage': text,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      _c.clear();
      if (mounted) {
        setState(() {
          _replyToId = null;
          _replyToData = null;
        });
      }
      await _markSeen();

    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Ошибка отправки: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      // Конфигурация под голос/речь (подходит для голосовых сообщений)
      await session.configure(const AudioSessionConfiguration.speech());
    } catch (_) {
     
    }
  }

  Future<void> _pickReaction(String msgId) async {
    final me = FirebaseAuth.instance.currentUser!;
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) =>
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: ['👍', '❤️', '😂', '😮', '😢', '👏', '🔥', '🎉'].map((e) {
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, e),
                    child: Text(e, style: const TextStyle(fontSize: 28)),
                  );
                }).toList(),
              ),
            ),
          ),
    );
    if (emoji == null) return;

    final doc = await _messagesCol.doc(msgId).get();
    final data = doc.data() ?? {};
    final reactions =
        (data['reactions'] as Map?)?.cast<String, dynamic>() ?? {};
    final perEmoji = (reactions[emoji] as Map?)?.cast<String, dynamic>() ?? {};

    final reacted = perEmoji.containsKey(me.uid);
    await _messagesCol.doc(msgId).set({
      'reactions': {
        emoji: reacted ? {me.uid: FieldValue.delete()} : {me.uid: true},
      },
    }, SetOptions(merge: true));
  }
  Widget _highlighted(String text) {
    final q = _query.trim().toLowerCase();
    final urlRe = RegExp(r'(https?:\/\/[^\s]+)'); 

    final List<InlineSpan> spans = [];
    int index = 0;

    void pushPlain(String raw) {
      if (raw.isEmpty) return;
      if (q.isEmpty) {
        spans.add(TextSpan(text: raw));
        return;
      }
      
      final lower = raw.toLowerCase();
      int start = 0;
      while (true) {
        final hit = lower.indexOf(q, start);
        if (hit < 0) {
          spans.add(TextSpan(text: raw.substring(start)));
          break;
        }
        if (hit > start) {
          spans.add(TextSpan(text: raw.substring(start, hit)));
        }
        spans.add(TextSpan(
          text: raw.substring(hit, hit + q.length),
          style: const TextStyle(backgroundColor: Color(0xFFFFFF00)),
        ));
        start = hit + q.length;
      }
    }

    final matches = urlRe.allMatches(text).toList();
    for (var m in matches) {
      final start = m.start;
      final end = m.end;
      if (start > index) {
        pushPlain(text.substring(index, start));
      }
      final url = text.substring(start, end);
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: InkWell(
            onTap: () => _openUrl(url),
            child: Text(
              url,
              style: const TextStyle(
                color: Colors.blue,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      );
      index = end;
    }
    if (index < text.length) {
      pushPlain(text.substring(index));
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(color: Colors.black, height: 1.25),
        children: spans,
      ),
    );
  }

  Future<void> _pickAndSendImage() async {
    final me = FirebaseAuth.instance.currentUser!;
    final messenger = ScaffoldMessenger.of(context);
    final picker = ImagePicker();

    try {
      final xfile = await picker.pickImage(
          source: ImageSource.gallery, imageQuality: 85);
      if (xfile == null) return;

      setState(() => _sending = true);

      final fname = '${DateTime
          .now()
          .millisecondsSinceEpoch}_${me.uid}.jpg';
      final ref = FirebaseStorage.instance.ref().child(
          'chat_images/${widget.roomId}/$fname');

      String url;
      if (kIsWeb) {
        final bytes = await xfile.readAsBytes();
        await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
        url = await ref.getDownloadURL();
      } else {
        final file = File(xfile.path);
        await ref.putFile(file, SettableMetadata(contentType: 'image/jpeg'));
        url = await ref.getDownloadURL();
      }

      await _messagesCol.add({
        'type': 'image',
        'imageUrl': url,
        'text': '',
        'uid': me.uid,
        'email': me.email,
        'timestamp': FieldValue.serverTimestamp(),
        'clientTs': DateTime
            .now()
            .millisecondsSinceEpoch,
      });

      await FirebaseFirestore.instance
          .collection('rooms')
          .doc(widget.roomId)
          .set({
        'roomId': widget.roomId,
        'type': isDirectRoom(widget.roomId) ? 'dm' : _roomType,
        'lastMessage': '📷 Фото',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Не удалось отправить фото: $e')));
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        await _markSeen();
      }
    }
  }
  Future<void> _pickAndSendFile() async {
    final me = FirebaseAuth.instance.currentUser!;
    // ⚠️ кэшируем объекты, зависящие от context, ДО первых await
    final messenger = ScaffoldMessenger.of(context);


    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: kIsWeb, // web -> bytes
      );
      if (result == null || result.files.isEmpty) return;

      final f = result.files.first;
      final String fileName = f.name;
      final int fileSize = f.size;
      final String? path = f.path;      // null на Web
      final Uint8List? bytes = f.bytes; // Web/withData
      final String contentType = lookupMimeType(fileName) ?? 'application/octet-stream';

      final String fname = '${DateTime.now().millisecondsSinceEpoch}_${me.uid}_$fileName';
      final ref = FirebaseStorage.instance.ref().child('chat_files/${widget.roomId}/$fname');

      UploadTask uploadTask;
      if (kIsWeb) {
        if (bytes == null) {
          messenger.showSnackBar(const SnackBar(content: Text('Не удалось прочитать файл')));
          return;
        }
        uploadTask = ref.putData(bytes, SettableMetadata(contentType: contentType));
      } else {
        if (path == null) {
          messenger.showSnackBar(const SnackBar(content: Text('Не удалось получить путь к файлу')));
          return;
        }
        uploadTask = ref.putFile(File(path), SettableMetadata(contentType: contentType));
      }

      setState(() {
        _currentUpload = uploadTask;
        _uploadProgress = 0;
        _sending = true;
      });

      uploadTask.snapshotEvents.listen((s) {
        final total = s.totalBytes;
        final done = s.bytesTransferred;
        if (total > 0 && mounted) {
          setState(() => _uploadProgress = done / total);
        }
      }, onError: (_) {
        if (!mounted) return;
        setState(() {
          _currentUpload = null;
          _uploadProgress = null;
          _sending = false;
        });
      });

      final snap = await uploadTask;
      final url = await snap.ref.getDownloadURL();

      await _messagesCol.add({
        'type': 'file',
        'fileUrl': url,
        'fileName': fileName,
        'fileSize': fileSize,
        'contentType': contentType,
        'uid': me.uid,
        'email': me.email,
        'timestamp': FieldValue.serverTimestamp(),
        'clientTs': DateTime.now().millisecondsSinceEpoch,
      });

      await FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).set({
        'roomId': widget.roomId,
        'type': isDirectRoom(widget.roomId) ? 'dm' : _roomType,
        'lastMessage': '📎 $fileName',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

    } catch (e) {
      
      messenger.showSnackBar(SnackBar(content: Text('Не удалось отправить файл: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _currentUpload = null;
          _uploadProgress = null;
          _sending = false;
        });
        await _markSeen();
      }
    }
  }
  Future<void> _startRecording() async {
    if (_isRecording) return;

    final hasPerm = await _recorder.hasPermission();
    if (!hasPerm) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет разрешения на микрофон')),
      );
      return;
    }

    final dir = await getTemporaryDirectory();
    _recPath = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
      ),
      path: _recPath!,
    );

    setState(() {
      _isRecording = true;
      _recMs = 0;
    });

    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recMs += 1000);
    });
  }
  Future<void> _cancelRecording() async {
    if (!_isRecording) return;
    _recTimer?.cancel();
    await _recorder.stop();
    if (_recPath != null) {
      try { File(_recPath!).deleteSync(); } catch (_) {}
    }
    setState(() {
      _isRecording = false;
      _recPath = null;
      _recMs = 0;
    });
  }

  Future<void> _stopAndSendRecording() async {
    final me = FirebaseAuth.instance.currentUser!;
    final messenger = ScaffoldMessenger.of(context);

    try {
      final path = await _recorder.stop();
      _recTimer?.cancel();
      if (path == null) {
        messenger.showSnackBar(const SnackBar(content: Text('Запись не получена')));
        return;
      }

      final fname = '${DateTime.now().millisecondsSinceEpoch}_${me.uid}.m4a';
      final ref = FirebaseStorage.instance.ref().child('chat_audio/${widget.roomId}/$fname');

      final uploadTask = ref.putFile(File(path), SettableMetadata(contentType: 'audio/mp4'));
      setState(() {
        _currentUpload = uploadTask;
        _uploadProgress = 0;
        _sending = true;
      });

      uploadTask.snapshotEvents.listen((s) {
        final total = s.totalBytes;
        final done = s.bytesTransferred;
        if (total > 0 && mounted) {
          setState(() => _uploadProgress = done / total);
        }
      });

      final snap = await uploadTask;
      final url = await snap.ref.getDownloadURL();

      await _messagesCol.add({
        'type': 'audio',
        'audioUrl': url,
        'durationMs': _recMs,
        'uid': me.uid,
        'email': me.email,
        'timestamp': FieldValue.serverTimestamp(),
        'clientTs': DateTime.now().millisecondsSinceEpoch,
      });

      await FirebaseFirestore.instance.collection('rooms').doc(widget.roomId).set({
        'roomId': widget.roomId,
        'type': isDirectRoom(widget.roomId) ? 'dm' : _roomType,
        'lastMessage': '🎤 Голосовое',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Не удалось отправить голосовое: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _recMs = 0;
          _recPath = null;
          _currentUpload = null;
          _uploadProgress = null;
          _sending = false;
        });
        await _markSeen();
      }
    }
  }
  Future<void> _editMessage(String msgId, String oldText) async {
    final messenger = ScaffoldMessenger.of(context);
    final c = TextEditingController(text: oldText);

    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(
                title: const Text('Редактировать сообщение'),
                content: TextField(
                  controller: c,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
        ) ??
            false;

    if (!ok) return;
    final newText = c.text.trim();
    if (newText.isEmpty || newText == oldText) return;

    try {
      await _messagesCol.doc(msgId).update({
        'text': newText,
        'edited': true,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Не удалось изменить: $e')),
      );
    }
  }

  Future<void> _deleteMessage(String msgId) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) =>
              AlertDialog(
                title: const Text('Удалить сообщение?'),
                content: const Text('Действие нельзя отменить.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Удалить'),
                  ),
                ],
              ),
        ) ??
            false;

    if (!ok) return;

    try {
      await _messagesCol.doc(msgId).delete();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Не удалось удалить: $e')));
    }
  }
  void _showMsgMenu({
    required String msgId,
    required String text,
    required bool isMe,
  }) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) =>
          SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                
                ListTile(
                  leading: const Icon(Icons.add_reaction),
                  title: const Text('Реакция'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickReaction(msgId);
                  },
                ),
               
                ListTile(
                  leading: const Icon(Icons.reply),
                  title: const Text('Ответить'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _replyToId = msgId;
                      _replyToData = {'text': text};
                    });
                  },
                ),
              
                ListTile(
                  leading: const Icon(Icons.content_copy),
                  title: const Text('Копировать'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(
                        const SnackBar(content: Text('Скопировано')));
                  },
                ),
                if (isMe) ...[
                  ListTile(
                    leading: const Icon(Icons.edit),
                    title: const Text('Редактировать'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _editMessage(msgId, text);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: const Text('Удалить'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _deleteMessage(msgId);
                    },
                  ),
                ],
              ],
            ),
          ),
    );
  }

  Widget _audioBubble(String id, String url, {int? durationMs}) {
    
    final AudioPlayer player = _audioPlayers.putIfAbsent(id, () => AudioPlayer());

    
    if (_audioInited.add(id)) {
      player.setUrl(url).catchError((_) => null);
      player.playerStateStream.listen((st) async {
        if (st.processingState == ProcessingState.completed) {
          try {
            await player.seek(Duration.zero);
            await player.pause();
          } catch (_) {}
          if (mounted && _playingId == id) {
            setState(() => _playingId = null);
          }
        }
      });
    }

    final Duration fallbackDuration = Duration(milliseconds: durationMs ?? 0);

    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      initialData: player.duration ?? fallbackDuration,
      builder: (context, durSnap) {
        final total = durSnap.data ?? fallbackDuration;
        final int maxMs = total.inMilliseconds > 0 ? total.inMilliseconds : 1;

        return StreamBuilder<Duration>(
          stream: player.positionStream,
          initialData: player.position,
          builder: (context, posSnap) {
            final Duration pos = posSnap.data ?? Duration.zero;
            final int curMs = pos.inMilliseconds.clamp(0, maxMs);
            final bool playing = player.playing;

            String fmt(Duration d) {
              final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
              final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
              return '$m:$s';
            }

            return Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
                    iconSize: 32,
                    onPressed: () async {
                      
                      if (_playingId != null && _playingId != id) {
                        final other = _audioPlayers[_playingId!];
                        await other?.pause();
                      }
                      _playingId = id;
                      if (player.playing) {
                        await player.pause();
                      } else {
                        final dur = player.duration ?? total;
                        if (pos >= dur) {                     
                          await player.seek(Duration.zero);
                        }
                        await player.play();
                      }
                      if (mounted) setState(() {});
                    },
                  ),
                  IconButton(
                    tooltip: '−10 сек',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () async {
                      final p = player.position - const Duration(seconds: 10);
                      await player.seek(p < Duration.zero ? Duration.zero : p);
                    },
                  ),
                  IconButton(
                    tooltip: '+10 сек',
                    icon: const Icon(Icons.forward_10),
                    onPressed: () async {
                      final p = player.position + const Duration(seconds: 10);
                      final dur = player.duration ?? total;
                      await player.seek(p > dur ? dur : p);
                    },
                  ),

                 
                  TextButton(
                    onPressed: () async {
                      final cur = _audioSpeed[id] ?? 1.0;
                      final next = (cur < 1.5) ? 1.5 : (cur < 2.0) ? 2.0 : 1.0;
                      try { await player.setSpeed(next); } catch (_) {}
                      _audioSpeed[id] = next;
                      if (mounted) setState(() {});
                    },
                    child: Text('${(_audioSpeed[id] ?? 1.0)}x'),
                  ),
                  SizedBox(
                    width: 160,
                    child: Slider(
                      value: curMs.toDouble(),
                      max: maxMs.toDouble(),
                      onChanged: (v) async {
                        await player.seek(Duration(milliseconds: v.toInt()));
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${fmt(pos)} / ${fmt(total)}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
  Widget _composer() {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyToId != null)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  const Icon(Icons.reply, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (_replyToData?['text'] as String?)?.trim() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Отменить ответ',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _replyToId = null;
                      _replyToData = null;
                    }),
                  ),
                ],
              ),
            ),

          
          if (_currentUpload != null)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cloud_upload),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: (_uploadProgress ?? 0).clamp(0.0, 1.0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Отменить загрузку',
                    icon: const Icon(Icons.close),
                    onPressed: _cancelCurrentUpload,
                  ),
                ],
              ),
            ),

         
          if (_isRecording)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mic, color: Colors.red),
                  const SizedBox(width: 8),
                  Text('Идёт запись • ${_fmtMs(_recMs)}'),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _cancelRecording,
                    icon: const Icon(Icons.close),
                    label: const Text('Отмена'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _stopAndSendRecording,
                    icon: const Icon(Icons.send),
                    label: const Text('Отправить'),
                  ),
                ],
              ),
            ),

          
          Row(
            children: [
              IconButton(
                tooltip: _showEmoji ? 'Клавиатура' : 'Эмодзи',
                icon: Icon(_showEmoji ? Icons.keyboard : Icons.emoji_emotions_outlined),
                onPressed: () {
                  setState(() => _showEmoji = !_showEmoji);
                  if (_showEmoji) {
                    _inputFocus.unfocus();
                  } else {
                    _inputFocus.requestFocus();
                  }
                },
              ),
              IconButton(
                tooltip: _isRecording ? 'Идёт запись' : 'Голосовое',
                icon: Icon(_isRecording ? Icons.mic : Icons.mic_none),
                color: _isRecording ? Colors.red : null,
                onPressed: _sending
                    ? null
                    : () async {
                  if (_isRecording) {
                    await _stopAndSendRecording();
                  } else {
                    await _startRecording();
                  }
                },
              ),
              IconButton(
                tooltip: 'Файл',
                icon: const Icon(Icons.attach_file),
                onPressed: _sending ? null : _pickAndSendFile, 
              ),

              IconButton(
                tooltip: 'Фото',
                icon: const Icon(Icons.image),
                onPressed: _sending ? null : _pickAndSendImage,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: TextField(
                    focusNode: _inputFocus,
                    controller: _c,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Введите сообщение...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => _notifyTyping(),
                    onSubmitted: (_) => _sendText(),
                    onTap: () {
                      if (_showEmoji) setState(() => _showEmoji = false);
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: _sending ? null : _sendText,
                  icon: _sending
                      ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.send),
                  label: const Text('Отпр.'),
                ),
              ),
            ],
          ),

          
          if (_showEmoji)
            SizedBox(
              height: 280,
              child: EmojiPicker(
                onEmojiSelected: (category, emoji) {
                  _c
                    ..text += emoji.emoji
                    ..selection = TextSelection.fromPosition(
                      TextPosition(offset: _c.text.length),
                    );
                },
                config: const Config(
                  emojiViewConfig: EmojiViewConfig(columns: 7),
                  bottomActionBarConfig: BottomActionBarConfig(enabled: false),
                  categoryViewConfig: CategoryViewConfig(tabBarHeight: 36),
                ),
              ),
            ),
        ],
      ),
    );
  }
  Widget _chatBody(int otherLastReadMs) {
    final me = FirebaseAuth.instance.currentUser;

    return Column(
      children: [
        if (_offline)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.12),
            padding: const EdgeInsets.all(8),
            child: const Text('Нет соединения', textAlign: TextAlign.center),
          ),

        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _messagesCol
                .orderBy('clientTs', descending: true)
                .limit(_limit)
                .snapshots(includeMetadataChanges: true),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(child: Text('Ошибка: ${snap.error}'));
              }

              List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
                  snap.data?.docs ?? <QueryDocumentSnapshot<Map<String, dynamic>>>[];

              
              if (_query.isNotEmpty) {
                final q = _query.toLowerCase();
                docs = docs.where((d) {
                  final m = d.data();
                  final t = (m['text'] as String?) ?? '';
                  return t.toLowerCase().contains(q);
                }).toList();
              }

              if (docs.isEmpty) {
                return const Center(child: Text('Ничего не найдено'));
              }

              return Stack(
                children: [
                  ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    itemCount: docs.length,
                    itemBuilder: (context, i) {
                      final doc = docs[i];
                      final m = doc.data();

                      final isMe = me != null && m['uid'] == me.uid;
                      final type = (m['type'] as String?) ?? 'text';
                      final text = (m['text'] as String?) ?? '';
                      final email = (m['email'] as String?) ?? 'unknown';
                      final clientTs = (m['clientTs'] as int?) ?? 0;
                      final edited = (m['edited'] as bool?) == true;

                     
                      final bool isSendingLocal = doc.metadata.hasPendingWrites;

                     
                      final bool isGroup = _roomType == 'group';

                     
                      final imageUrl = (m['imageUrl'] as String?) ?? '';
                      final audioUrl = (m['audioUrl'] as String?) ?? '';
                      final String fileUrl = (m['fileUrl'] as String?) ?? '';
                      final String fileName = (m['fileName'] as String?) ?? '';
                      final int fileSize = (m['fileSize'] as int?) ?? 0;
                      final String contentType =
                          (m['contentType'] as String?) ?? 'application/octet-stream';
                      final int? durationMs = m['durationMs'] as int?;

                   
                      final String authorUid = (m['uid'] as String?) ?? '';
                      final Map<String, dynamic> authorInfo =
                          (_participantsInfo[authorUid] as Map<String, dynamic>?) ?? const {};
                      final String authorName =
                          (authorInfo['displayName'] as String?) ?? email;
                      final String? authorPhoto = authorInfo['photoUrl'] as String?;

                 
                      final Map<String, dynamic>? reply =
                      m['replyTo'] is Map ? (m['replyTo'] as Map).cast<String, dynamic>() : null;
                      final String repliedText =
                          (reply?['text'] as String?)?.trim() ?? '';
                      final String? repliedId = reply?['id'] as String?;
                      final key = _msgKeys.putIfAbsent(doc.id, () => GlobalKey());

                     
                      final readByOther = isMe && isDirectRoom(widget.roomId)
                          ? (otherLastReadMs >= clientTs)
                          : false;

                      
                      final Map<String, dynamic> reactionsRaw =
                          (m['reactions'] as Map?)?.cast<String, dynamic>() ?? {};
                      final myUid = me?.uid;
                      final List<Widget> reactionChips = [];
                      reactionsRaw.forEach((emoji, val) {
                        if (val is Map) {
                          final usersMap = val.cast<String, dynamic>();
                          final count = usersMap.length;
                          if (count > 0) {
                            final iReacted = myUid != null && usersMap.containsKey(myUid);
                            reactionChips.add(
                              Container(
                                margin: const EdgeInsets.only(top: 6, right: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: iReacted
                                      ? Colors.white70
                                      : Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: iReacted
                                        ? Colors.blue
                                        : Colors.grey.shade300,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(emoji, style: const TextStyle(fontSize: 14)),
                                    const SizedBox(width: 4),
                                    Text(
                                      '$count',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        }
                      });

                     
                      Widget messageContent;
                      if (type == 'file' && fileUrl.isNotEmpty) {
                       
                        final kb = (fileSize / 1024).toStringAsFixed(0);
                        messageContent = InkWell(
                          onTap: () => _openUrl(fileUrl),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.9),
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.insert_drive_file, size: 28),
                                const SizedBox(width: 10),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 220),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        fileName,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '$contentType • ${kb}KB',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(Icons.open_in_new, size: 18),
                              ],
                            ),
                          ),
                        );
                      } else if (type == 'audio' && audioUrl.isNotEmpty) {
                        
                        messageContent =
                            _audioBubble(doc.id, audioUrl, durationMs: durationMs);
                      } else if (type == 'image' && imageUrl.isNotEmpty) {
                        
                        final tag = 'img_${doc.id}';
                        Widget img = GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => FullscreenImageScreen(
                                  url: imageUrl,
                                  heroTag: tag,
                                ),
                              ),
                            );
                          },
                          child: Hero(
                            tag: tag,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: imageUrl,
                                width: 220,
                                fit: BoxFit.cover,
                                placeholder: (ctx, _) => const SizedBox(
                                  width: 220,
                                  height: 160,
                                  child: Center(
                                    child: SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    ),
                                  ),
                                ),
                                errorWidget: (ctx, _, __) => const SizedBox(
                                  width: 220,
                                  height: 160,
                                  child: Center(
                                    child: Icon(Icons.broken_image, size: 32),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );

                        messageContent = (text.isNotEmpty)
                            ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            img,
                            const SizedBox(height: 6),
                            _highlighted(text),
                          ],
                        )
                            : img;
                      } else {
                       
                        messageContent = _highlighted(text);
                      }

                     
                      Widget? linkPreview;
                      if (type == 'text' && text.isNotEmpty) {
                        final urlInText = _extractFirstUrl(text);
                        if (urlInText != null) {
                          linkPreview = Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: AnyLinkPreview(
                              link: urlInText,
                              displayDirection: UIDirection.uiDirectionHorizontal,
                              showMultimedia: true,
                              bodyMaxLines: 2,
                              bodyTextOverflow: TextOverflow.ellipsis,
                              titleStyle: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              bodyStyle: const TextStyle(fontSize: 12),
                              removeElevation: true,
                              placeholderWidget: Container(
                                height: 80,
                                alignment: Alignment.center,
                                child: const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                              errorBody: 'Не удалось загрузить превью',
                              cache: const Duration(days: 7),
                            ),
                          );
                        }
                      }

                     
                      double dragDx = 0;

                      return KeyedSubtree(
                        key: key,
                        child: Align(
                          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              if (!isMe && details.primaryDelta != null) {
                                final delta = details.primaryDelta!;
                                if (delta > 0) dragDx += delta; 
                              }
                            },
                            onHorizontalDragEnd: (_) {
                              if (!isMe && dragDx > 24) {
                                setState(() {
                                  _replyToId = doc.id;
                                  _replyToData = {'text': text};
                                });
                              }
                              dragDx = 0;
                            },
                            child: InkWell(
                              onLongPress: () => _showMsgMenu(
                                msgId: doc.id,
                                text: text,
                                isMe: isMe,
                              ),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.blue.shade100
                                      : Colors.grey.shade200,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: (doc.id == _highlightId)
                                        ? Colors.amber
                                        : Colors.transparent,
                                    width: (doc.id == _highlightId) ? 2 : 0,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: isMe
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                   
                                    if (repliedText.isNotEmpty)
                                      InkWell(
                                        onTap: repliedId != null
                                            ? () => _jumpToMessage(repliedId)
                                            : null,
                                        child: Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(8),
                                          margin: const EdgeInsets.only(bottom: 6),
                                          decoration: BoxDecoration(
                                            color: Colors.white70,
                                            border: Border(
                                              left: BorderSide(
                                                color: Colors.blue.shade300,
                                                width: 3,
                                              ),
                                            ),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            repliedText,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.grey.shade800,
                                              fontStyle: FontStyle.italic,
                                            ),
                                          ),
                                        ),
                                      ),
                                   
                                    if (isGroup && !isMe) ...[
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          UserAvatar(
                                            photoUrl: authorPhoto,
                                            title: authorName,
                                            radius: 12,
                                          ),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text(
                                              authorName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                              Theme.of(context).textTheme.labelSmall,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                    ],

                                    
                                    messageContent,

                                    
                                    if (linkPreview != null) linkPreview,

                                    if (edited)
                                      Text(
                                        'изменено',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey[600],
                                        ),
                                      ),

                                    if (isMe) ...[
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isSendingLocal
                                                ? Icons.access_time
                                                : (readByOther
                                                ? Icons.done_all
                                                : Icons.check),
                                            size: 16,
                                            color: isSendingLocal
                                                ? Colors.grey
                                                : (readByOther
                                                ? Colors.blue
                                                : Colors.grey),
                                          ),
                                        ],
                                      ),
                                    ],

                                    if (reactionChips.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Wrap(children: reactionChips),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (_showJumpToBottom)
                    Positioned(
                      right: 12,
                      bottom: 12,
                      child: FloatingActionButton.small(
                        heroTag: 'fab_jump_bottom',
                        tooltip: 'Вниз',
                        onPressed: _scrollToBottom,
                        child: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ),

                ],
              );
            },
          ),
        ),
        _composer(),
      ],
    );
  }
  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    final isDm = myUid != null && isDirectRoom(widget.roomId);
    final otherUid = (myUid != null)
        ? otherUidFromRoom(widget.roomId, myUid)
        : null;

    return Scaffold(
      appBar: AppBar(
        
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isDm ? 'Личный чат' : 'Публичный чат'),
            if (isDm && otherUid != null)
              StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                stream: _roomRef.snapshots(), // rooms/{roomId}
                builder: (context, snap) {
                  final data = snap.data?.data();
                  final typingMap = (data?['typing'] as Map?)?.cast<String, dynamic>() ?? {};
                  final otherTyping = typingMap[otherUid] == true;

                  if (otherTyping) {
                    return const Text('печатает…', style: TextStyle(fontSize: 12));
                  }

                 
                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance.collection('users').doc(otherUid).snapshots(),
                    builder: (context, uSnap) {
                      final u = uSnap.data?.data();
                      if (u == null) return const SizedBox.shrink();
                      final online = u['online'] == true;
                      if (online) return const Text('в сети', style: TextStyle(fontSize: 12));
                      final lastSeen = u['lastSeen'];
                      if (lastSeen is Timestamp) {
                        final dt = lastSeen.toDate();
                        final hh = dt.hour.toString().padLeft(2, '0');
                        final mm = dt.minute.toString().padLeft(2, '0');
                        return Text('был(а): $hh:$mm', style: const TextStyle(fontSize: 12));
                      }
                      return const SizedBox.shrink();
                    },
                  );
                },
              ),
          ],
        ),

       
        actions: [
          IconButton(
            tooltip: _searchMode ? 'Закрыть поиск' : 'Поиск',
            icon: Icon(_searchMode ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searchMode = !_searchMode;
                if (!_searchMode) _query = '';
              });
            },
          ),
          
          if (isDm && otherUid != null)
            IconButton(
              tooltip: 'Аудио/видео звонок',
              icon: const Icon(Icons.videocam),
              onPressed: () async {
                final video = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Тип звонка'),
                    content: const Text('Видео-звонок? (Нет = только аудио)'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Нет')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Да')),
                    ],
                  ),
                ) ?? true;

                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CallScreen.caller(calleeUid: otherUid, video: video)),
                );
              },
            ),
          IconButton(
            onPressed: () => FirebaseAuth.instance.signOut(),
            icon: const Icon(Icons.logout),
          ),
        ],

        bottom: _searchMode
            ? PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _SearchBar(
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        )
            : null,
      ),

      body: (isDm && otherUid != null)
          ? StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('rooms')
            .doc(widget.roomId)
            .collection('members')
            .doc(otherUid)
            .snapshots(),
        builder: (context, memberSnap) {
          final otherLastRead = memberSnap.data?.data()?['lastReadAt'];
          final otherLastReadMs = (otherLastRead is Timestamp)
              ? otherLastRead
              .toDate()
              .millisecondsSinceEpoch
              : 0;
          return _chatBody(otherLastReadMs);
        },
      )
          : _chatBody(0),
    );
  }
}


class _SearchBar extends StatelessWidget {
  final ValueChanged<String> onChanged;

  const _SearchBar({required this.onChanged});


  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: TextField(
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Поиск по сообщениям…',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
