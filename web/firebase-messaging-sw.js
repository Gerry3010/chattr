// Firebase Messaging Service Worker
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.1/firebase-messaging-compat.js');

// Initialize Firebase in the service worker
firebase.initializeApp({
  apiKey: "YOUR_FIREBASE_API_KEY", // nosemgrep: detected-generic-api-key -- public Firebase Web config, not a secret
  authDomain: "your-firebase-project.firebaseapp.com",
  projectId: "your-firebase-project",
  storageBucket: "your-firebase-project.firebasestorage.app",
  messagingSenderId: "YOUR_MESSAGING_SENDER_ID",
  appId: "YOUR_FIREBASE_APP_ID"
});

// Retrieve an instance of Firebase Messaging
const messaging = firebase.messaging();

// Handle background messages
messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Received background message ', payload);
  
  // Web pushes are data-only (title/body in payload.data) so the FCM SDK
  // doesn't auto-display a second notification next to ours. Keep the
  // notification-block fallback for messages sent during rollout.
  const notificationTitle = payload.notification?.title || payload.data?.title || 'Chattr';
  const notificationOptions = {
    body: payload.notification?.body || payload.data?.body || 'New message',
    icon: '/favicon.png',
    badge: '/favicon.png',
    tag: payload.data?.chat_id || 'chattr-notification',
    data: payload.data,
    requireInteraction: false,
  };

  return self.registration.showNotification(notificationTitle, notificationOptions);
});

// Handle notification click
self.addEventListener('notificationclick', (event) => {
  console.log('[firebase-messaging-sw.js] Notification click received.', event);
  
  event.notification.close();
  
  // Get notification data
  const data = event.notification.data;
  
  // Open or focus the app window
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      // Try to find an existing window
      for (const client of clientList) {
        if (client.url.includes('chattr') && 'focus' in client) {
          return client.focus();
        }
      }
      
      // Open new window if none found
      if (clients.openWindow) {
        const url = data?.chat_id ? `/chat/${data.chat_id}` : '/';
        return clients.openWindow(url);
      }
    })
  );
});
