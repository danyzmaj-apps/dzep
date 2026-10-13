package com.danyzmaj.dzep

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import org.json.JSONObject

/**
 * omp sessions followed in the notification shade: one ongoing notification
 * per session, Android's take on the iPhone's Live Activities
 * (ios/Shared/OmpActivity.swift). Dart starts, updates and ends them while
 * the app runs (lib/live_activity.dart); otherwise the server updates them by
 * push (PushService), sent to this phone's FCM token once per followed
 * session. A tap opens the session; swiping one away stops following it.
 */
object OmpActivities {
    private const val PREFS = "dzep_activities"

    /** What a followed session shows; [since] and [updated] in ms since 1970. */
    private data class Shown(
        val title: String,
        val project: String,
        val state: String,
        val kind: String?,
        val since: Long,
        /** When the Mac last said anything about it (start, update, push). */
        val updated: Long = System.currentTimeMillis(),
    )

    /** As the iPhone's staleDate: Working with no word for this long reads "No word lately". */
    private const val STALE_AFTER = 8 * 3600 * 1000L

    private val states = setOf("working", "needs", "done", "ended")

    private fun prefs(c: Context) = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun load(c: Context, key: String): Shown? = prefs(c).getString(key, null)?.let {
        runCatching {
            val j = JSONObject(it)
            Shown(
                j.getString("title"),
                j.getString("project"),
                j.getString("state"),
                j.optString("kind").ifEmpty { null },
                j.getLong("since"),
                j.optLong("updated", System.currentTimeMillis()),
            )
        }.getOrNull()
    }

    private fun save(c: Context, key: String, s: Shown) {
        val j = JSONObject()
            .put("title", s.title).put("project", s.project).put("state", s.state).put("since", s.since)
            .put("updated", s.updated)
        if (s.kind != null) j.put("kind", s.kind)
        prefs(c).edit().putString(key, j.toString()).commit()
    }

    private fun tag(key: String) = "omp:$key"

    /** The followed sessions' keys. */
    fun keys(c: Context): List<String> = prefs(c).all.keys.toList()

    /** {key, token?} for each one; the token is the phone's FCM token. */
    fun running(c: Context): List<Map<String, String>> {
        val token = DzepShared.fcmToken(c)
        return keys(c).map { if (token == null) mapOf("key" to it) else mapOf("key" to it, "token" to token) }
    }

    /**
     * {key, title, project, state, kind?, since}: starts following the
     * session, or updates it. False: notifications are off for Džep.
     */
    @Synchronized
    fun start(c: Context, args: Map<*, *>): Boolean {
        val key = args["key"] as? String ?: return false
        val state = (args["state"] as? String)?.takeIf { it in states } ?: return false
        if (!Notifications.allowed(c)) return false
        val old = load(c, key)
        val s = Shown(
            title = args["title"] as? String ?: old?.title ?: "omp",
            project = args["project"] as? String ?: old?.project ?: "",
            state = state,
            kind = args["kind"] as? String,
            since = (args["since"] as? Number)?.toLong() ?: System.currentTimeMillis(),
        )
        save(c, key, s)
        show(c, key, s)
        staleLater(c, key)
        return true
    }

    /** {key, state, kind?, since}; false if [key] isn't followed. */
    @Synchronized
    fun update(c: Context, args: Map<*, *>): Boolean {
        val key = args["key"] as? String ?: return false
        val old = load(c, key) ?: return false
        val state = (args["state"] as? String)?.takeIf { it in states } ?: return false
        if (state == "ended") {
            end(c, key, immediate = false)
            return true
        }
        val s = old.copy(
            state = state,
            kind = args["kind"] as? String,
            since = (args["since"] as? Number)?.toLong() ?: System.currentTimeMillis(),
            updated = System.currentTimeMillis(),
        )
        save(c, key, s)
        show(c, key, s)
        staleLater(c, key)
        return true
    }

    /**
     * Stops following [key]: gone at once ([immediate]: the person ended it),
     * or Ended for 10 minutes (the session ended on the Mac). Either way Dart
     * hears activityEnded, as from the iPhone.
     */
    @Synchronized
    fun end(c: Context, key: String, immediate: Boolean) {
        val old = load(c, key)
        prefs(c).edit().remove(key).commit()
        if (immediate || old == null) {
            Notifications.cancel(c, tag(key))
        } else {
            show(c, key, old.copy(state = "ended", kind = null, since = System.currentTimeMillis()))
        }
        if (old != null) ended(c, key)
    }

    /** A push from the server: {session, state, since, akind?}. */
    fun pushed(c: Context, m: JSONObject) {
        val key = m.optString("session").ifEmpty { return }
        val args = mutableMapOf<String, Any>("key" to key, "state" to m.optString("state"))
        if (m.has("since")) args["since"] = m.getLong("since")
        m.optString("akind").ifEmpty { null }?.let { args["kind"] = it }
        // Not followed (any more): the server stops once Dart says so.
        update(c, args)
    }

    /** Swiped away. */
    @Synchronized
    fun dismissed(c: Context, key: String) {
        if (load(c, key) == null) return
        prefs(c).edit().remove(key).commit()
        ended(c, key)
    }

    private fun ended(c: Context, key: String) {
        val token = DzepShared.fcmToken(c)
        NativeEvents.emit("activityEnded", if (token == null) mapOf("key" to key) else mapOf("key" to key, "token" to token))
    }

    /** Checks [key] again once it could have gone [STALE_AFTER] without word. */
    private fun staleLater(c: Context, key: String) {
        val pi = PendingIntent.getBroadcast(
            c,
            0,
            Intent(c, ActivityStaleReceiver::class.java)
                .setData(Uri.fromParts("dzep-stale", key, null))
                .putExtra("key", key),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Inexact is fine: it only changes the wording.
        c.getSystemService(AlarmManager::class.java)
            .set(AlarmManager.RTC, System.currentTimeMillis() + STALE_AFTER, pi)
    }

    /** The stale check came due: a session still Working with no word since shows "No word lately". */
    @Synchronized
    fun checkStale(c: Context, key: String) {
        val s = load(c, key) ?: return
        if (s.state == "working" && System.currentTimeMillis() - s.updated >= STALE_AFTER - 60_000) {
            show(c, key, s, stale = true)
        }
    }

    /** Working with the time since it started (or No word lately), Needs you with what for, Finished, or Ended. */
    private fun show(c: Context, key: String, s: Shown, stale: Boolean = false) {
        Notifications.ensureChannels(c)
        val (text, color) = when (s.state) {
            "working" -> (if (stale) "No word lately" else "Working") to (if (stale) R.color.dzep_dim else R.color.dzep_accent)
            "needs" -> when (s.kind) {
                "question" -> "Needs you · Question"
                "approval" -> "Needs you · Approval"
                "plan" -> "Needs you · Plan review"
                else -> "Needs you"
            } to R.color.dzep_warn
            "done" -> "Finished" to R.color.dzep_ok
            else -> "Ended" to R.color.dzep_dim
        }
        val live = s.state != "ended"
        val link = Uri.Builder().scheme("dzep").authority("session").appendQueryParameter("key", key).build()
        val open = PendingIntent.getActivity(
            c,
            tag(key).hashCode(),
            Intent(Intent.ACTION_VIEW, link, c, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = NotificationCompat.Builder(c, Notifications.FOLLOWED)
            .setSmallIcon(R.drawable.ic_stat_dzep)
            .setColor(c.getColor(color))
            .setContentTitle(s.title)
            .setContentText(text)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setOngoing(live)
            .setContentIntent(open)
            // Working counts up from when it started, like the iPhone's timer.
            .setWhen(s.since)
            .setShowWhen(s.state == "working" && !stale)
            .setUsesChronometer(s.state == "working" && !stale)
        if (s.project.isNotEmpty()) b.setSubText(s.project)
        if (live) {
            b.setDeleteIntent(
                PendingIntent.getBroadcast(
                    c,
                    tag(key).hashCode(),
                    Intent(c, ActivityDismissReceiver::class.java).putExtra("key", key),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        } else {
            b.setAutoCancel(true).setTimeoutAfter(10 * 60 * 1000L)
        }
        Notifications.post(c, tag(key), b.build())
    }
}

/** A followed session's notification was swiped away: stop following it. */
class ActivityDismissReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        OmpActivities.dismissed(c, intent.getStringExtra("key") ?: return)
    }
}

/** A followed session may have gone quiet (OmpActivities.staleLater). */
class ActivityStaleReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        OmpActivities.checkStale(c, intent.getStringExtra("key") ?: return)
    }
}
