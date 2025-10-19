// lib/core/widgets/unread_dot.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UnreadDot extends StatelessWidget {
  final String roomId;
  const UnreadDot({super.key, required this.roomId});

  @override
  Widget build(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) return const SizedBox.shrink();

    final roomRef = FirebaseFirestore.instance.collection('rooms').doc(roomId);
    final myMemberRef = roomRef.collection('members').doc(myUid);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: myMemberRef.snapshots(),
      builder: (context, memberSnap) {
        if (memberSnap.connectionState == ConnectionState.waiting ||
            memberSnap.hasError) {
          return const SizedBox.shrink();
        }

        
        final lastReadAt = memberSnap.data?.data()?['lastReadAt'];
        final lastReadMs = (lastReadAt is Timestamp)
            ? lastReadAt.toDate().millisecondsSinceEpoch
            : 0;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: roomRef
              .collection('messages')
              .where('clientTs', isGreaterThan: lastReadMs)
              .limit(1)
              .snapshots(),
          builder: (context, msgSnap) {
            if (msgSnap.connectionState == ConnectionState.waiting ||
                msgSnap.hasError) {
              return const SizedBox.shrink();
            }

            final hasUnread = msgSnap.data?.docs.isNotEmpty ?? false;
            return hasUnread
                ? Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Colors.redAccent,
                shape: BoxShape.circle,
              ),
            )
                : const SizedBox.shrink();
          },
        );
      },
    );
  }
}
