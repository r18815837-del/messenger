/* web/firebase-messaging-sw.js */

// Подключаем Firebase (compat-версии для SW)
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.2/firebase-messaging-compat.js');

// Конфиг твоего проекта (взято из Firebase Console)
// ВАЖНО: storageBucket скорректирован на appspot.com
firebase.initializeApp({
  apiKey: "AIzaSyCLFCUE3H_zv7oPLxvANVIJNPqYlnPreR0",
  authDomain: "quickchat-86c7b.firebaseapp.com",
  projectId: "quickchat-86c7b",
  storageBucket: "quickchat-86c7b.appspot.com",
  messagingSenderId: "1045888649731",
  appId: "1:1045888649731:web:b761fc35827e8c4aad1c36",
  // measurementId не обязателен для SW
});

const messaging = firebase.messaging();

// Получение фоновых сообщений (когда вкладка закрыта/неактивна)
messaging.onBackgroundMessage((payload) => {
  // console.log('[firebase-messaging-sw.js] Background message:', payload);

  const title =
    (payload.notification && payload.notification.title) ||
    (payload.data && payload.data.title) ||
    'Новое сообщение';

  const body =
    (payload.notification && payload.notification.body) ||
    (payload.data && payload.data.body) ||
    '';

  const clickAction =
    (payload.notification && payload.notification.click_action) ||
    (payload.data && payload.data.click_action) ||
    '/';

  const options = {
    body,
    icon: '/icons/Icon-192.png', // иконка из Flutter web
    badge: '/icons/Icon-48.png',
    data: { link: clickAction },
  };

  self.registration.showNotification(title, options);
});

// Переход по клику на уведомление
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.link) || '/';
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
