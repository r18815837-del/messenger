import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcCall {
  final String callId;
  final RTCPeerConnection pc;
  final MediaStream localStream;
  final ValueNotifier<MediaStream?> remoteStream = ValueNotifier<MediaStream?>(null);

  final DocumentReference<Map<String, dynamic>> callRef;
  final CollectionReference<Map<String, dynamic>> callerCandRef;
  final CollectionReference<Map<String, dynamic>> calleeCandRef;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _docSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _calleeCandSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _callerCandSub;

  WebRtcCall({
    required this.callId,
    required this.pc,
    required this.localStream,
    required this.callRef,
    required this.callerCandRef,
    required this.calleeCandRef,
  });

  Future<void> dispose() async {
    try { await _docSub?.cancel(); } catch (_) {}
    try { await _calleeCandSub?.cancel(); } catch (_) {}
    try { await _callerCandSub?.cancel(); } catch (_) {}
    try { await pc.close(); } catch (_) {}
    try { await localStream.dispose(); } catch (_) {}
  }
}

class WebRtcCallService {
  WebRtcCallService(this._db, this._auth);
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  final Map<String, WebRtcCall> _calls = {};

  Future<RTCPeerConnection> _createPc() {
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };
    final constraints = {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };
    return createPeerConnection(config, constraints);
  }

  Future<MediaStream> _getUserMedia({required bool video}) {
    final constraints = <String, dynamic>{
      'audio': true,
      'video': video
          ? {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      }
          : false,
    };
    return navigator.mediaDevices.getUserMedia(constraints);
  }

  // === Caller ===
  Future<WebRtcCall> startCall({required String calleeUid, required bool video}) async {
    final me = _auth.currentUser!;
    final callDoc = _db.collection('calls').doc();

    final pc = await _createPc();
    final local = await _getUserMedia(video: video);

    // attach local
    for (final t in local.getTracks()) {
      await pc.addTrack(t, local);
    }

    // remote
    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        _calls[callDoc.id]?.remoteStream.value = e.streams[0];
      }
    };

    // write ICE from caller
    final callerCandRef = callDoc.collection('callerCandidates');
    final calleeCandRef = callDoc.collection('calleeCandidates');

    pc.onIceCandidate = (c) async {
      if (c.candidate == null) return;
      await callerCandRef.add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex   // ✅ с заглавной L
        ,
      });
    };

    // create offer
    final offer = await pc.createOffer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': video ? 1 : 0});
    await pc.setLocalDescription(offer);

    await callDoc.set({
      'callerUid': me.uid,
      'calleeUid': calleeUid,
      'video': video,
      'status': 'ringing',
      'offer': {'sdp': offer.sdp, 'type': offer.type},
      'createdAt': FieldValue.serverTimestamp(),
    });

    final call = WebRtcCall(
      callId: callDoc.id,
      pc: pc,
      localStream: local,
      callRef: callDoc,
      callerCandRef: callerCandRef,
      calleeCandRef: calleeCandRef,
    );
    _calls[callDoc.id] = call;

    // listen answer
    call._docSub = callDoc.snapshots().listen((snap) async {
      final d = snap.data();
      if (d == null) return;

      final rd = await pc.getRemoteDescription(); // ✅
      if (d['answer'] != null && rd == null) {
        final ans = d['answer'] as Map<String, dynamic>;
        await pc.setRemoteDescription(
          RTCSessionDescription(ans['sdp'], ans['type']),
        );
        await call.callRef.update({'status': 'connected'});
      }

      if (d['status'] == 'ended') {
        await endCall(callDoc.id);
      }
    });

    // remote ICE (from callee)
    call._calleeCandSub = calleeCandRef.snapshots().listen((q) async {
      for (final dc in q.docChanges) {
        if (dc.type == DocumentChangeType.added) {
          final c = dc.doc.data()!;
          await pc.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        }
      }
    });

    return call;
  }

  // === Callee ===
  Future<WebRtcCall> joinCall({required String callId}) async {
    // ignore: unused_local_variable
    final me = _auth.currentUser!;
    final callDoc = _db.collection('calls').doc(callId);
    final snap = await callDoc.get();
    final data = snap.data()!;
    final video = (data['video'] as bool?) ?? true;

    final pc = await _createPc();
    final local = await _getUserMedia(video: video);

    for (final t in local.getTracks()) {
      await pc.addTrack(t, local);
    }

    final callerCandRef = callDoc.collection('callerCandidates');
    final calleeCandRef = callDoc.collection('calleeCandidates');

    pc.onTrack = (e) {
      if (e.streams.isNotEmpty) {
        _calls[callDoc.id]?.remoteStream.value = e.streams[0];
      }
    };

    pc.onIceCandidate = (c) async {
      if (c.candidate == null) return;
      await calleeCandRef.add({
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    // read offer
    final offer = data['offer'] as Map<String, dynamic>;
    await pc.setRemoteDescription(RTCSessionDescription(offer['sdp'], offer['type']));

    // create answer
    final answer = await pc.createAnswer({'offerToReceiveAudio': 1, 'offerToReceiveVideo': video ? 1 : 0});
    await pc.setLocalDescription(answer);

    await callDoc.update({
      'answer': {'sdp': answer.sdp, 'type': answer.type},
      'status': 'connected',
    });

    final call = WebRtcCall(
      callId: callDoc.id,
      pc: pc,
      localStream: local,
      callRef: callDoc,
      callerCandRef: callerCandRef,
      calleeCandRef: calleeCandRef,
    );
    _calls[callDoc.id] = call;

    // caller ICE
    call._callerCandSub = callerCandRef.snapshots().listen((q) async {
      for (final dc in q.docChanges) {
        if (dc.type == DocumentChangeType.added) {
          final c = dc.doc.data()!;
          await pc.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        }
      }
    });

    // end listener
    call._docSub = callDoc.snapshots().listen((s) async {
      if (s.data()?['status'] == 'ended') {
        await endCall(callId);
      }
    });

    return call;
  }

  Future<void> endCall(String callId) async {
    final call = _calls.remove(callId);
    if (call == null) return;
    try {
      await call.callRef.set({'status': 'ended', 'endedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    } catch (_) {}
    await call.dispose();
  }
}
