package com.danyzmaj.dzep

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Pushes from the user's own server, through the relay
 * (supabase/functions/relay) and FCM. They are data-only: {kind, enc}, enc
 * being {kind, title, body, id?, session?} or, for a followed session,
 * {kind: activity, session, state, since, akind?}, sealed with this phone's
 * push key (DzepShared.open). The relay and Google only ever see ciphertext.
 * If it doesn't open, the relay's generic text shows, as on the iPhone.
 */
class PushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        DzepShared.setFcmToken(this, token)
        // The server needs the new one: for the phone, and for each followed session.
        NativeEvents.emit("pushToken")
        for (key in SessionActivities.keys(this)) {
            NativeEvents.emit("activityToken", mapOf("key" to key, "token" to token))
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val kind = message.data["kind"] ?: return
        val m = message.data["enc"]?.let { DzepShared.open(this, it) }
        when (kind) {
            "activity" -> if (m != null) SessionActivities.pushed(this, m)
            "reminder" ->
                if (m == null) {
                    Notifications.todo(this, null, "Džep", "Reminder")
                } else {
                    Notifications.todo(this, m.optString("id").ifEmpty { null }, m.optString("title"), m.optString("body"))
                }
            "terminal" ->
                if (m == null) {
                    Notifications.terminal(this, null, "Džep", "Terminal")
                } else {
                    Notifications.terminal(
                        this,
                        m.optString("session").ifEmpty { null },
                        m.optString("title"),
                        m.optString("body"),
                    )
                }
        }
    }
}
