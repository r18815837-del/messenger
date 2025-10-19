// lib/features/call/presentation/call_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';

class CallScreen extends StatefulWidget {
  final bool isCaller;
  final String? calleeUid; // если я инициирую звонок
  final String? callerUid; // если звонят мне
  final String? callId;    // id документа calls/{callId}
  final bool video;

  const CallScreen._internal({
    super.key,
    required this.isCaller,
    required this.video,
    this.calleeUid,
    this.callerUid,
    this.callId,
  });

  /// Инициатор звонка
  factory CallScreen.caller({
    Key? key,
    required String calleeUid,
    bool video = true,
  }) {
    return CallScreen._internal(
      key: key,
      isCaller: true,
      calleeUid: calleeUid,
      video: video,
    );
  }

  /// Получатель (входящий) — создаётся из listener-а входящих
  factory CallScreen.receiver({
    Key? key,
    required String callId,
    required String callerUid,
    bool video = true,
  }) {
    return CallScreen._internal(
      key: key,
      isCaller: false,
      callId: callId,
      callerUid: callerUid,
      video: video,
    );
  }

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  // ---- Firebase / user ----
  final _me = FirebaseAuth.instance.currentUser!;
  final _db = FirebaseFirestore.instance;

  // ---- WebRTC ----
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  // входящий — пока не приняли
  bool _incoming = false;
  bool _accepted = false;
  Map<String, dynamic>? _incomingOffer;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];

  // ---- сигналинг ----
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _candsSub;

  // ---- состояние ----
  String? _callId;
  String _status = 'Подключение…';
  bool _micOn = true;
  bool _camOn = true;
  bool _ended = false;
  bool _speakerOn = true;
  bool _usingFront = true;
  AudioPlayer? _ring;
  Timer? _callTimeout;

  // STUN/TURN (замени на свой TURN в проде)
  final Map<String, dynamic> _rtcConfig = const {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
       {
       'urls': ['turn:YOUR_TURN_HOST:3478'],
        'username': 'user',
         'credential': 'pass',
       },
    ],
    'sdpSemantics': 'unified-plan',
  };

  @override
  void initState() {
    super.initState();
    _initRenderers();
    WakelockPlus.enable();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!await _ensurePermissions()) return;
      if (widget.isCaller) {
        await _startAsCaller();
      } else {
        _incoming = true;
        _status = 'Входящий звонок…';
        setState(() {});
        await _prepareIncoming();
      }
    });
  }

  @override
  void dispose() {
    _endAndPop(); // идемпотентно
    try { WakelockPlus.disable(); } catch (_) {}
    try { _localRenderer.dispose(); } catch (_) {}
    try { _remoteRenderer.dispose(); } catch (_) {}
    super.dispose();
  }

  // ---------- helpers ----------
  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<bool> _ensurePermissions() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Нет доступа к микрофону');
      return false;
    }
    if (widget.video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        _toast('Нет доступа к камере');
        return false;
      }
    }
    return true;
  }

  Future<void> _createPc() async {
    _pc = await createPeerConnection(_rtcConfig);

    // Хотим и слать, и принимать медиа
    await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );
    if (widget.video) {
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
    }

    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams[0];
        _stopRinging();
        try { Helper.setSpeakerphoneOn(true); } catch (_) {}
        if (mounted) setState(() => _status = 'Соединено');
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate c) async {
      if (_callId == null || c.candidate == null) return;
      await _db.collection('calls').doc(_callId).collection('candidates').add({
        'sender': _me.uid,
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
        'createdAt': FieldValue.serverTimestamp(),
      });
    };

    _pc!.onConnectionState = (RTCPeerConnectionState s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _stopRinging();
        try { Helper.setSpeakerphoneOn(true); } catch (_) {}
        if (mounted) setState(() => _status = 'Соединено');
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        if (mounted) _endAndPop();
      }
    };
  }

  Future<MediaStream> _openUserMedia() async {
    final media = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': widget.video ? {'facingMode': 'user'} : false,
    });
    _localRenderer.srcObject = media;
    try { await Helper.setSpeakerphoneOn(true); } catch (_) {}
    return media;
  }

  // ---------- Рингтон ----------
  Future<void> _startRinging({required bool outgoing}) async {
    try {
      _ring?.dispose();
      _ring = AudioPlayer();
      await _ring!.setAsset('assets/sounds/ring.mp3');
      await _ring!.setLoopMode(LoopMode.one);
      await _ring!.play();
    } catch (_) {}

    // таймаут ответа 35 сек
    _callTimeout?.cancel();
    _callTimeout = Timer(const Duration(seconds: 35), () async {
      if (mounted && _status != 'Соединено') {
        try {
          if (_callId != null) {
            await _db.collection('calls').doc(_callId)
                .set({'status': 'no_answer'}, SetOptions(merge: true));
          }
        } catch (_) {}
        _toast('Нет ответа');
        _endAndPop();
      }
    });
  }

  void _stopRinging() {
    try { _ring?.stop(); } catch (_) {}
    try { _ring?.dispose(); } catch (_) {}
    _ring = null;
    _callTimeout?.cancel();
    _callTimeout = null;
  }

  // ===================== CALLER FLOW =====================
  Future<void> _startAsCaller() async {
    setState(() => _status = 'Вызов…');

    await _createPc();

    _localStream = await _openUserMedia();
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    // создаём документ звонка
    final ref = _db.collection('calls').doc();
    _callId = ref.id;

    await ref.set({
      'callerUid': _me.uid,
      'calleeUid': widget.calleeUid,
      'video': widget.video,
      'status': 'ringing',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // offer
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    await ref.update({'offer': {'sdp': offer.sdp, 'type': offer.type}});

    await _startRinging(outgoing: true);

    // ждём answer/окончание
    _docSub?.cancel();
    _docSub = ref.snapshots().listen((ds) async {
      final d = ds.data();
      if (d == null) return;

      final ans = d['answer'];
      if (ans != null) {
        final current = await _pc?.getRemoteDescription();
        if (current == null) {
          final answer = RTCSessionDescription(ans['sdp'], ans['type']);
          await _pc!.setRemoteDescription(answer);

          // добавить отложенные ICE
          if (_pendingRemoteCandidates.isNotEmpty) {
            for (final c in List<RTCIceCandidate>.from(_pendingRemoteCandidates)) {
              try { await _pc!.addCandidate(c); } catch (_) {}
            }
            _pendingRemoteCandidates.clear();
          }
          _stopRinging();
          _callTimeout?.cancel();
          _callTimeout = null;
          if (mounted) setState(() => _status = 'Соединено');
        }
      }

      final st = d['status'] as String?;
      if (st == 'ended' || st == 'no_answer') {
        if (mounted) _endAndPop();
      }
    });

    // ICE от собеседника
    _candsSub?.cancel();
    _candsSub = ref
        .collection('candidates')
        .where('sender', isNotEqualTo: _me.uid)
        .snapshots()
        .listen((qs) async {
      for (final ch in qs.docChanges) {
        if (ch.type != DocumentChangeType.added) continue;
        final m = ch.doc.data();
        if (m == null) continue;

        final candidate = RTCIceCandidate(
          m['candidate'] as String?,
          m['sdpMid'] as String?,
          m['sdpMLineIndex'] as int?,
        );

        final rd = await _pc?.getRemoteDescription();
        if (rd == null) {
          _pendingRemoteCandidates.add(candidate);
        } else {
          try { await _pc!.addCandidate(candidate); } catch (_) {}
        }
      }
    });
  }

  // ===================== INCOMING (ожидание «принять/отклонить») =====================
  Future<void> _prepareIncoming() async {
    final ref = _db.collection('calls').doc(widget.callId);
    _callId = ref.id;

    final ds = await ref.get();
    if (!ds.exists) {
      _toast('Звонок не найден');
      if (mounted) Navigator.pop(context);
      return;
    }
    final d = ds.data()!;
    final offerMap = d['offer'];
    if (offerMap == null) {
      _toast('Нет SDP offer');
      if (mounted) Navigator.pop(context);
      return;
    }
    _incomingOffer = Map<String, dynamic>.from(offerMap);

    await _startRinging(outgoing: false);

    // следим за завершением
    _docSub?.cancel();
    _docSub = ref.snapshots().listen((snap) {
      final data = snap.data();
      if (data == null) return;
      final st = data['status'] as String?;
      if (st == 'ended' || st == 'no_answer') {
        _stopRinging();
        if (mounted) _endAndPop();
      }
    });

    // буферим ICE до принятия
    _candsSub?.cancel();
    _candsSub = ref
        .collection('candidates')
        .where('sender', isNotEqualTo: _me.uid)
        .snapshots()
        .listen((qs) {
      for (final ch in qs.docChanges) {
        if (ch.type != DocumentChangeType.added) continue;
        final m = ch.doc.data();
        if (m == null) continue;
        final cand = RTCIceCandidate(
          m['candidate'] as String?,
          m['sdpMid'] as String?,
          m['sdpMLineIndex'] as int?,
        );
        _pendingRemoteCandidates.add(cand);
      }
    });

    setState(() {}); // показать кнопки Принять/Отклонить
  }

  // ===================== Принять / Отклонить =====================
  Future<void> _acceptCall() async {
    if (_accepted) return;
    _accepted = true;
    _incoming = false;
    _stopRinging();
    setState(() => _status = 'Соединение…');

    final ref = _db.collection('calls').doc(_callId);

    await _createPc();

    _localStream = await _openUserMedia();
    for (final t in _localStream!.getTracks()) {
      await _pc!.addTrack(t, _localStream!);
    }

    // применяем сохранённый offer
    final offer = RTCSessionDescription(_incomingOffer!['sdp'], _incomingOffer!['type']);
    await _pc!.setRemoteDescription(offer);

    // добавить буферизированные ICE
    if (_pendingRemoteCandidates.isNotEmpty) {
      for (final c in List<RTCIceCandidate>.from(_pendingRemoteCandidates)) {
        try { await _pc!.addCandidate(c); } catch (_) {}
      }
      _pendingRemoteCandidates.clear();
    }

    // answer
    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    await ref.update({
      'answer': {'sdp': answer.sdp, 'type': answer.type},
      'status': 'accepted',
    });

    // дальше уже в onTrack / onConnectionState поставится Соединено
    setState(() {});
  }

  Future<void> _declineCall() async {
    try {
      if (_callId != null) {
        await _db.collection('calls').doc(_callId)
            .set({'status': 'ended'}, SetOptions(merge: true));
      }
    } catch (_) {}
    _stopRinging();
    _endAndPop();
  }

  // ===================== UI actions =====================
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _toggleMic() async {
    _micOn = !_micOn;
    for (final t in _localStream?.getAudioTracks() ?? []) {
      t.enabled = _micOn;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleCam() async {
    if (!widget.video) return;
    _camOn = !_camOn;
    for (final t in _localStream?.getVideoTracks() ?? []) {
      t.enabled = _camOn;
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleSpeaker() async {
    _speakerOn = !_speakerOn;
    try { await Helper.setSpeakerphoneOn(_speakerOn); } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    if (!widget.video) return;
    final tracks = _localStream?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
      _usingFront = !_usingFront;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _hangup() async {
    _stopRinging();
    try {
      if (_callId != null) {
        await _db.collection('calls').doc(_callId)
            .set({'status': 'ended'}, SetOptions(merge: true));
      }
    } catch (_) {}
    _endAndPop();
  }

  void _endAndPop() {
    if (_ended) return;
    _ended = true;

    _stopRinging();

    try { _docSub?.cancel(); } catch (_) {}
    try { _candsSub?.cancel(); } catch (_) {}

    try { _pc?.close(); } catch (_) {}
    _pc = null;

    try {
      for (final t in _localStream?.getTracks() ?? const []) { t.stop(); }
      _localStream?.dispose();
    } catch (_) {}
    _localStream = null;

    try { _localRenderer.srcObject = null; } catch (_) {}
    try { _remoteRenderer.srcObject = null; } catch (_) {}

    try { Helper.setSpeakerphoneOn(false); } catch (_) {}

    if (mounted) Navigator.of(context).maybePop();
  }

  // ===================== UI =====================
  @override
  Widget build(BuildContext context) {
    final isVideo = widget.video;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _hangup();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(_status),
        ),
        body: Stack(
          children: [
            // REMOTE
            Positioned.fill(
              child: isVideo
                  ? RTCVideoView(
                _remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              )
                  : Center(
                child: Icon(
                  Icons.call,
                  size: 120,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),

            // LOCAL PIP
            if (isVideo)
              Positioned(
                top: 24,
                right: 16,
                width: 120,
                height: 160,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(_localRenderer, mirror: true),
                  ),
                ),
              ),

            // ПАНЕЛЬ «Принять / Отклонить» (входящий, не принят)
            if (_incoming && !_accepted)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _roundBtn(
                      bg: Colors.green,
                      icon: Icons.call,
                      onTap: _acceptCall,
                    ),
                    const SizedBox(width: 24),
                    _roundBtn(
                      bg: Colors.red,
                      icon: Icons.call_end,
                      onTap: _declineCall,
                    ),
                  ],
                ),
              ),

            // Основные контролы (исходящий ИЛИ входящий принят)
            if (!_incoming || _accepted)
              Positioned(
                left: 0,
                right: 0,
                bottom: 24,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _roundBtn(
                      icon: _micOn ? Icons.mic : Icons.mic_off,
                      onTap: _toggleMic,
                    ),
                    const SizedBox(width: 18),
                    if (isVideo)
                      _roundBtn(
                        icon: _camOn ? Icons.videocam : Icons.videocam_off,
                        onTap: _toggleCam,
                      ),
                    const SizedBox(width: 18),
                    _roundBtn(
                      icon: _speakerOn ? Icons.volume_up : Icons.volume_off,
                      onTap: _toggleSpeaker,
                    ),
                    const SizedBox(width: 18),
                    if (isVideo)
                      _roundBtn(
                        icon: Icons.cameraswitch,
                        onTap: _switchCamera,
                      ),
                    const SizedBox(width: 18),
                    _roundBtn(
                      bg: Colors.red,
                      icon: Icons.call_end,
                      onTap: _hangup,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roundBtn({
    required IconData icon,
    required VoidCallback onTap,
    Color bg = const Color(0x22FFFFFF),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
