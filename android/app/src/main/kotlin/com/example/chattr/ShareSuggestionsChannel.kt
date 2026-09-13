// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

package net.geraldhofbauer.chattr

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.core.app.Person
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * QuickShare — Android share-sheet Direct Share row.
 *
 * The Android counterpart to `ios/Runner/ShareSuggestionsChannel.swift`, behind
 * the SAME Dart channel name and the same three methods, so one Dart file drives
 * both platforms.
 *
 * **Why not `share_handler.recordSentMessage`.** The plugin ships exactly this
 * donation — but only the donation. It has no counterpart for removing a
 * shortcut, so a logout or a "turn the feature off" would leave the names of
 * chat partners sitting in the launcher and the share sheet. The Dart layer
 * already promises `deleteAll` / `deleteConversations`; honouring that promise
 * is why this file exists.
 *
 * **How the row is fed.** Android 10+ picks Direct Share targets exclusively
 * from *long-lived, conversation-flagged dynamic shortcuts* whose category
 * matches a `<share-target>` in `res/xml/shortcuts.xml`. A plain `ACTION_SEND`
 * intent filter (which we also have) only lands the app in the list *below* that
 * row. Both pieces are required; either one alone shows nothing.
 *
 * **Privacy.** Same policy as iOS: no message content, ever. What leaves the app
 * is a display name, an opaque chat id, and — since the avatar cache exists — the
 * chat's picture as a local file. All three go to the system shortcut store on
 * this device, never to a server, and `deleteAll` takes them back.
 */
object ShareSuggestionsChannel {
    private const val CHANNEL = "net.geraldhofbauer.chattr/share_suggestions"

    /**
     * Category that ties a shortcut to the `<share-target>` declaration.
     * Must stay identical to the `<category>` in `res/xml/shortcuts.xml` —
     * a mismatch is silent: the shortcuts exist, the row stays empty.
     */
    private const val SHARE_TARGET_CATEGORY =
        "net.geraldhofbauer.chattr.dynamic_share_target"

    /**
     * Android caps dynamic shortcuts per app (`getMaxShortcutCountPerActivity`,
     * commonly 15 and never below 5). Publishing more throws
     * `IllegalArgumentException` and would take the whole send down with it, so
     * we stay well under any reported cap and let the oldest fall off.
     */
    private const val MAX_SHORTCUTS = 4

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "donateSend" -> {
                        donateSend(app, call.argument("conversationId"),
                            call.argument("conversationName"),
                            call.argument("isGroup") ?: false,
                            call.argument("recipients"),
                            call.argument("conversationImagePath"))
                        result.success(true)
                    }
                    "deleteAll" -> {
                        ShortcutManagerCompat.removeAllDynamicShortcuts(app)
                        result.success(true)
                    }
                    "deleteConversations" -> {
                        val ids = call.argument<List<String>>("conversationIds")
                            ?: emptyList()
                        if (ids.isNotEmpty()) {
                            // removeLongLivedShortcuts also unpublishes from the
                            // share sheet; removeDynamicShortcuts alone can leave
                            // a cached long-lived target behind on some versions.
                            ShortcutManagerCompat.removeLongLivedShortcuts(app, ids)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                // A suggestion is a nicety; a send, a logout and a chat deletion
                // are not. Never let this path throw into the caller.
                result.error("share_suggestions_failed", e.message, null)
            }
        }
    }

    private fun donateSend(
        context: Context,
        conversationId: String?,
        conversationName: String?,
        isGroup: Boolean,
        recipients: List<Map<String, Any?>>?,
        conversationImagePath: String?,
    ) {
        if (conversationId.isNullOrEmpty()) return
        val names = recipients.orEmpty()
            .mapNotNull { it["displayName"] as? String }
            .filter { it.isNotBlank() }
        // A group keeps its own title; a 1:1 is labelled by the other person.
        val label = (if (isGroup) conversationName else names.firstOrNull())
            ?.takeIf { it.isNotBlank() }
            ?: names.firstOrNull()
            ?: return // nothing nameable — a blank chip helps nobody

        // Selecting this target hands MainActivity the ORIGINAL ACTION_SEND
        // intent plus `android.intent.extra.shortcut.ID`; share_handler reads
        // that extra (and this fallback one) into SharedMedia.conversationIdentifier.
        // The intent below is what a tap in the LAUNCHER's long-press menu fires
        // — same shape, so both routes land in the same Dart handler.
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_SEND
            putExtra("conversationIdentifier", conversationId)
        }

        // A group is shown by its own picture; a 1:1 by the other person's. Both
        // arrive as LOCAL FILES — the system draws this row itself and cannot
        // fetch a URL (see ShareSuggestionAvatarCache on the Dart side). Absent
        // or unreadable simply means no icon, which is what it looked like
        // before pictures existed at all.
        val imagePath = if (isGroup) {
            conversationImagePath
        } else {
            recipients.orEmpty().firstNotNullOfOrNull { it["avatarPath"] as? String }
        }
        val icon = imagePath
            ?.let { runCatching { BitmapFactory.decodeFile(it) }.getOrNull() }
            ?.let { IconCompat.createWithAdaptiveBitmap(it) }

        val person = Person.Builder()
            .setKey(conversationId)
            .setName(label)
            .apply { if (icon != null) setIcon(icon) }
            .build()

        val shortcut = ShortcutInfoCompat.Builder(context, conversationId)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIsConversation()
            .setLongLived(true)
            .setCategories(setOf(SHARE_TARGET_CATEGORY))
            .setPerson(person)
            .setIntent(intent)
            .apply { if (icon != null) setIcon(icon) }
            .build()

        // Re-donating an existing id updates it and refreshes its rank rather
        // than adding a duplicate. Trim first so we never cross the cap.
        trimTo(context, MAX_SHORTCUTS - 1, keep = conversationId)
        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut)
    }

    /** Drops the least recently updated shortcuts until at most [max] remain. */
    private fun trimTo(context: Context, max: Int, keep: String) {
        val existing = ShortcutManagerCompat.getDynamicShortcuts(context)
            .filter { it.id != keep }
        if (existing.size <= max) return
        val stale = existing
            .sortedBy { it.lastChangedTimestamp }
            .take(existing.size - max)
            .map { it.id }
        ShortcutManagerCompat.removeLongLivedShortcuts(context, stale)
    }
}
