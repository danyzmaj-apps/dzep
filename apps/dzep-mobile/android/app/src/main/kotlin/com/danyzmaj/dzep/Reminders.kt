package com.danyzmaj.dzep

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/** The notification channels and what posts to them. */
object Notifications {
    const val REMINDERS = "reminders"
    const val SESSIONS = "sessions"
    const val FOLLOWED = "followed"

    /** Intent extras for MainActivity: what a tap opens. */
    const val EXTRA_TODO = "com.danyzmaj.dzep.todo"
    const val EXTRA_SESSION = "com.danyzmaj.dzep.session"

    fun ensureChannels(c: Context) {
        val m = c.getSystemService(NotificationManager::class.java)
        m.createNotificationChannels(
            listOf(
                NotificationChannel(REMINDERS, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Todo reminders, with Done to tick them off."
                },
                NotificationChannel(SESSIONS, "omp sessions", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "An omp session on your Mac finished or needs you."
                },
                NotificationChannel(FOLLOWED, "Followed sessions", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "What a followed omp session is doing, kept up to date."
                    setShowBadge(false)
                },
            ),
        )
    }

    /** Android 13+ asks; before that it's on unless turned off in Settings. */
    fun allowed(c: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(c).areNotificationsEnabled()

    fun post(c: Context, tag: String, n: android.app.Notification) {
        if (!allowed(c)) return
        try {
            NotificationManagerCompat.from(c).notify(tag, 1, n)
        } catch (e: SecurityException) {
            // Permission withdrawn between the check and the post.
        }
    }

    fun cancel(c: Context, tag: String) = NotificationManagerCompat.from(c).cancel(tag, 1)

    /** Opens the app; [extras] say on what. */
    fun openApp(c: Context, request: String, extras: Intent.() -> Unit = {}): PendingIntent =
        PendingIntent.getActivity(
            c,
            request.hashCode(),
            Intent(c, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                extras()
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /**
     * A todo's reminder, local or pushed: a tap opens the app on it; Done
     * ticks it off the way the Todos widget does, with the app closed.
     * Without [id] (a push that names no todo) it only opens the app.
     */
    fun todo(c: Context, id: String?, title: String?, body: String) {
        ensureChannels(c)
        val tag = "todo:${id ?: System.currentTimeMillis()}"
        val b = NotificationCompat.Builder(c, REMINDERS)
            .setSmallIcon(R.drawable.ic_stat_dzep)
            .setColor(c.getColor(R.color.dzep_accent))
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openApp(c, tag) { if (id != null) putExtra(EXTRA_TODO, id) })
        if (title != null) b.setContentTitle(title)
        if (id != null) {
            val done = PendingIntent.getBroadcast(
                c,
                tag.hashCode(),
                Intent(c, DoneReceiver::class.java).putExtra(EXTRA_TODO, id),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            b.addAction(0, "Done", done)
        }
        post(c, tag, b.build())
    }

    /** A terminal push: a tap opens that omp session. */
    fun terminal(c: Context, session: String?, title: String, body: String) {
        ensureChannels(c)
        val tag = "terminal:${session ?: System.currentTimeMillis()}"
        val n = NotificationCompat.Builder(c, SESSIONS)
            .setSmallIcon(R.drawable.ic_stat_dzep)
            .setColor(c.getColor(R.color.dzep_accent))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openApp(c, tag) { if (session != null) putExtra(EXTRA_SESSION, session) })
            .build()
        post(c, tag, n)
    }
}

/**
 * Todo reminders as alarms. Dart picks them (lib/remind.dart) and hands over
 * the whole set on every change; they're kept so a reboot can set them again.
 * Exact when Android allows it (Alarms & reminders), else within minutes.
 */
object Reminders {
    private const val PREFS = "dzep_reminders"

    private data class Reminder(val id: String, val title: String, val at: Long)

    private fun stored(c: Context): List<Reminder> {
        val raw = c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("list", null) ?: return emptyList()
        return runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).map {
                a.getJSONObject(it).let { r -> Reminder(r.getString("id"), r.getString("title"), r.getLong("at")) }
            }
        }.getOrDefault(emptyList())
    }

    private fun store(c: Context, list: List<Reminder>) {
        val a = JSONArray()
        for (r in list) a.put(JSONObject().put("id", r.id).put("title", r.title).put("at", r.at))
        c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("list", a.toString()).apply()
    }

    private fun alarm(c: Context, r: Reminder, flags: Int): PendingIntent? = PendingIntent.getBroadcast(
        c,
        0,
        Intent(c, ReminderReceiver::class.java)
            // The data makes each todo's alarm its own PendingIntent.
            .setData(Uri.fromParts("dzep-reminder", r.id, null))
            .putExtra("id", r.id)
            .putExtra("title", r.title),
        PendingIntent.FLAG_IMMUTABLE or flags,
    )

    /** Replaces every pending reminder with [list] ({id, title, at: ms since 1970}). */
    @Synchronized
    fun schedule(c: Context, list: List<Map<*, *>>) {
        val alarms = c.getSystemService(AlarmManager::class.java)
        for (r in stored(c)) alarm(c, r, PendingIntent.FLAG_NO_CREATE)?.let { alarms.cancel(it); it.cancel() }
        val next = list.mapNotNull { m ->
            val id = m["id"] as? String ?: return@mapNotNull null
            val title = m["title"] as? String ?: return@mapNotNull null
            val at = (m["at"] as? Number)?.toLong() ?: return@mapNotNull null
            Reminder(id, title, at)
        }
        store(c, next)
        set(c, next)
    }

    /** After a reboot or an update, or once exact alarms are allowed. */
    @Synchronized
    fun reschedule(c: Context) = set(c, stored(c))

    @Synchronized
    fun fired(c: Context, id: String) = store(c, stored(c).filter { it.id != id })

    private fun set(c: Context, list: List<Reminder>) {
        val alarms = c.getSystemService(AlarmManager::class.java)
        val exact = Build.VERSION.SDK_INT < 31 || alarms.canScheduleExactAlarms()
        for (r in list) {
            // One that came due while the phone was off goes off now.
            val at = maxOf(r.at, System.currentTimeMillis() + 1000)
            val pi = alarm(c, r, PendingIntent.FLAG_UPDATE_CURRENT) ?: continue
            if (exact) {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            } else {
                alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
            }
        }
    }
}

/** A reminder's alarm went off. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        val id = intent.getStringExtra("id") ?: return
        Reminders.fired(c, id)
        Notifications.todo(c, id, null, intent.getStringExtra("title") ?: return)
    }
}

/** A reminder's Done. */
class DoneReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        val id = intent.getStringExtra(Notifications.EXTRA_TODO) ?: return
        Notifications.cancel(c, "todo:$id")
        val pending = goAsync()
        DzepShared.complete(c, id) { pending.finish() }
    }
}

/** Alarms don't survive a reboot or an update; exact ones come once allowed. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> Reminders.reschedule(c)
        }
    }
}
