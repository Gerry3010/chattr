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

// ---------------------------------------------------------------------------
// Push ohne Klartext (Stufe 1)
// ---------------------------------------------------------------------------
// The server no longer sends the chat name or the sender's username to a
// device that says it can render locally — only ids. This worker turns them
// back into words using a cache the Flutter app mirrors into IndexedDB.
//
// Why IndexedDB and not the app's normal storage: shared_preferences on web is
// backed by localStorage, which is synchronous and window-scoped — a service
// worker has no window and cannot reach it. IndexedDB is the only store both
// sides can see. Names and wording are written together by
// lib/features/push_notifications/push_cache_bridge_web.dart; the db/store
// names below are mirrored there. Change both.

const CACHE_DB = 'chattr_push';
const CACHE_STORE = 'render_cache';

/** English defaults, mirroring PushTemplates.fallback on the Dart side. Used
 *  until the app has run once and filled the cache. */
const FALLBACK_TEMPLATES = {
  new_message: 'New message from {user}',
  new_message_unknown: 'New message',
  new_message_image: '{user} sent a photo',
  new_message_video: '{user} sent a video',
  new_message_audio: '{user} sent an audio file',
  new_message_file: '{user} sent a file',
  reaction: '{user} reacted to your message',
  reaction_unknown: 'Someone reacted to your message',
  member_request_title: 'New join request',
  member_request_body: '{user} wants to join {chat}',
  chat_fallback: 'Chattr',
  someone: 'Someone',
};

/** Read the mirrored cache. Resolves to empty on ANY problem — a cache miss
 *  costs a generic notification, never a missing one. */
function readRenderCache() {
  return new Promise((resolve) => {
    let settled = false;
    const done = (value) => {
      if (!settled) { settled = true; resolve(value); }
    };
    // Never hang the push handler on a wedged IndexedDB: the browser kills a
    // worker that takes too long, and that would drop the notification.
    setTimeout(() => done({ names: {}, templates: {} }), 1000);

    try {
      const request = indexedDB.open(CACHE_DB, 1);
      request.onupgradeneeded = () => {
        // The app has not written yet; create the store so this open succeeds
        // instead of erroring, and return empty.
        const db = request.result;
        if (!db.objectStoreNames.contains(CACHE_STORE)) {
          db.createObjectStore(CACHE_STORE);
        }
      };
      request.onerror = () => done({ names: {}, templates: {} });
      request.onsuccess = () => {
        const db = request.result;
        try {
          const store = db.transaction(CACHE_STORE, 'readonly')
            .objectStore(CACHE_STORE);
          const names = store.get('names');
          const templates = store.get('templates');
          let pending = 2;
          const result = { names: {}, templates: {} };
          const settle = () => { if (--pending === 0) { db.close(); done(result); } };
          const parse = (raw) => {
            try {
              const parsed = JSON.parse(raw || '{}');
              return (parsed && typeof parsed === 'object') ? parsed : {};
            } catch (_) { return {}; }
          };
          names.onsuccess = () => { result.names = parse(names.result); settle(); };
          names.onerror = settle;
          templates.onsuccess = () => { result.templates = parse(templates.result); settle(); };
          templates.onerror = settle;
        } catch (_) {
          db.close();
          done({ names: {}, templates: {} });
        }
      };
    } catch (_) {
      done({ names: {}, templates: {} });
    }
  });
}

/** Mirrors renderPush() in lib/features/push_notifications/push_local_renderer.dart.
 *  Keep the two in step — same fallbacks, same "unknown type renders nothing".
 *  Returns null when there is nothing meaningful to show. */
function renderPush(data, names, templates) {
  const t = (key) => templates[key] || FALLBACK_TEMPLATES[key];
  const str = (key) => (typeof data[key] === 'string' && data[key]) ? data[key] : null;
  const fill = (template, user, chat) => template
    .replace('{user}', user === undefined ? '' : user)
    .replace('{chat}', chat === undefined ? '' : chat);

  const chatId = str('chat_id');
  const chatName = chatId ? names[chatId] : null;
  const senderName = str('sender_id') ? names[str('sender_id')] : null;

  switch (str('type')) {
    case 'new_message': {
      // Mirrors the media branch in push_local_renderer.dart — an unknown or
      // absent media_kind falls back to the plain wording.
      const mediaKey = {
        image: 'new_message_image',
        video: 'new_message_video',
        audio: 'new_message_audio',
        other: 'new_message_file',
      }[str('media_kind')];
      return {
        // An unknown sender gets its own sentence: "New message from Someone"
        // reads like a bug.
        title: chatName || t('chat_fallback'),
        body: senderName
          ? fill(t(mediaKey || 'new_message'), senderName)
          : t('new_message_unknown'),
        chatId,
      };
    }
    case 'reaction':
      return {
        title: chatName || t('chat_fallback'),
        body: senderName ? fill(t('reaction'), senderName) : t('reaction_unknown'),
        chatId,
      };
    case 'member_request': {
      const requesterId = str('requester_id');
      return {
        title: t('member_request_title'),
        body: fill(
          t('member_request_body'),
          (requesterId && names[requesterId]) || t('someone'),
          chatName || t('chat_fallback'),
        ),
        chatId,
      };
    }
    default:
      // Server ahead of this build. A bare "Chattr" would be worse than
      // silence — the app picks the event up over realtime when opened.
      return null;
  }
}

// Handle background messages
messaging.onBackgroundMessage(async (payload) => {
  const data = payload.data || {};

  // Legacy payload (title/body still travelling) — a client that has not yet
  // told the server it can render locally, or a message sent during rollout.
  // Show it as before rather than dropping it.
  const legacyTitle = payload.notification?.title || data.title;
  const legacyBody = payload.notification?.body || data.body;
  if (legacyTitle || legacyBody) {
    return self.registration.showNotification(legacyTitle || 'Chattr', {
      body: legacyBody || 'New message',
      icon: '/favicon.png',
      badge: '/favicon.png',
      tag: data.chat_id || 'chattr-notification',
      data,
      requireInteraction: false,
    });
  }

  const cache = await readRenderCache();
  const rendered = renderPush(data, cache.names, cache.templates);
  if (!rendered) return;

  return self.registration.showNotification(rendered.title, {
    body: rendered.body,
    icon: '/favicon.png',
    badge: '/favicon.png',
    // One notification per chat: a second message replaces the first instead
    // of stacking, matching the Android renderer.
    tag: rendered.chatId || 'chattr-notification',
    data,
    requireInteraction: false,
  });
});

// Handle notification click
self.addEventListener('notificationclick', (event) => {
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
