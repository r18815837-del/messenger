// functions/index.js
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {initializeApp} = require("firebase-admin/app");
const {getFirestore} = require("firebase-admin/firestore");
const {getMessaging} = require("firebase-admin/messaging");

initializeApp();

exports.notifyOnNewMessage = onDocumentCreated(
    "rooms/{roomId}/messages/{msgId}",
    async (event) => {
      const snap = event.data;
      if (!snap) return;

      const msg = snap.data();
      const roomId = event.params.roomId;

      const db = getFirestore();
      const roomRef = db.doc(`rooms/${roomId}`);
      const roomSnap = await roomRef.get();
      if (!roomSnap.exists) return;

      const room = roomSnap.data() || {};
      const type = room.type || "dm";
      if (type !== "dm") return;

      const senderUid = msg.uid;
      const participants = Array.isArray(room.participants) ?
      room.participants :
      [];
      const targets = participants.filter((u) => u !== senderUid);
      if (targets.length === 0) return;

      const tokens = new Set();
      for (const uid of targets) {
        const ts = await db.collection(`users/${uid}/tokens`).get();
        ts.forEach((d) => tokens.add(d.id));
      }
      if (tokens.size === 0) return;

      const senderInfo = room.participantsInfo &&
      room.participantsInfo[senderUid];
      const senderEmail = senderInfo && senderInfo.email ?
      senderInfo.email :
      "Новое сообщение";

      const text = msg.type === "image" ?
      "Фото" :
      (msg.text || "Новое сообщение");

      const payload = {
        notification: {
          title: senderEmail,
          body: text.length > 100 ? text.slice(0, 97) + "…" : text,
        },
        data: {
          roomId,
          msgId: event.params.msgId,
          type: msg.type || "text",
        },
        android: {priority: "high"},
        apns: {headers: {"apns-priority": "10"}},
      };

      await getMessaging().sendEachForMulticast({
        tokens: Array.from(tokens),
        notification: payload.notification,
        data: payload.data,
        android: payload.android,
        apns: payload.apns,
      });
    },
);
