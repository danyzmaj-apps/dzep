package com.danyzmaj.dzep

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * What the app, its widgets, its notifications and its push service share,
 * in app-private storage: the backend (the Supabase project the user
 * connected, written by lib/backend.dart), the device token (written by
 * lib/mobile.dart at sign-in), a snapshot of open todos for the widget, the
 * push key, and actions queued while offline (the app replays them on next
 * open). Android's ios/Shared/DzepShared.swift.
 */
object DzepShared {
    private const val FILE = "dzep_shared"

    data class Todo(val id: String, val title: String)

    data class Backend(val url: String, val key: String)

    /** Network calls the widget and the notifications make with the app closed. */
    val io: ExecutorService = Executors.newSingleThreadExecutor()

    private fun prefs(c: Context): SharedPreferences = c.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun backend(c: Context): Backend? {
        val p = prefs(c)
        val url = p.getString("backendUrl", null) ?: return null
        val key = p.getString("backendKey", null) ?: return null
        return Backend(url, key)
    }

    fun setBackend(c: Context, backend: Backend?) {
        prefs(c).edit().apply {
            if (backend == null) {
                remove("backendUrl")
                remove("backendKey")
            } else {
                putString("backendUrl", backend.url)
                putString("backendKey", backend.key)
            }
        }.apply()
    }

    fun token(c: Context): String? = prefs(c).getString("token", null)

    fun setToken(c: Context, token: String?) {
        prefs(c).edit().apply { if (token == null) remove("token") else putString("token", token) }.apply()
    }

    fun todos(c: Context): List<Todo> {
        val raw = prefs(c).getString("todos", null) ?: return emptyList()
        return runCatching {
            val a = JSONArray(raw)
            (0 until a.length()).map { a.getJSONObject(it).let { t -> Todo(t.getString("id"), t.getString("title")) } }
        }.getOrDefault(emptyList())
    }

    /** False when nothing changed (the widget needn't redraw). */
    @Synchronized
    fun setTodos(c: Context, todos: List<Todo>): Boolean {
        if (todos == todos(c)) return false
        val a = JSONArray()
        for (t in todos) a.put(JSONObject().put("id", t.id).put("title", t.title))
        prefs(c).edit().putString("todos", a.toString()).apply()
        return true
    }

    /** The FCM token this phone registered (registerPush, PushService.onNewToken). */
    fun fcmToken(c: Context): String? = prefs(c).getString("fcmToken", null)

    fun setFcmToken(c: Context, token: String) {
        prefs(c).edit().putString("fcmToken", token).apply()
    }

    /**
     * This phone's push key (32 bytes): made here, given only to the user's
     * own server (functions/push), which seals each push with it; PushService
     * opens them. Made on first use, kept across sign-ins.
     */
    fun pushKey(c: Context): ByteArray? =
        prefs(c).getString("pushKey", null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    @Synchronized
    fun makePushKey(c: Context): ByteArray {
        pushKey(c)?.let { return it }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs(c).edit().putString("pushKey", Base64.encodeToString(key, Base64.NO_WRAP)).commit()
        return key
    }

    /**
     * A push's `enc`: base64(nonce 12 ‖ ciphertext ‖ tag 16), AES-256-GCM with
     * [pushKey]. Null if anything is off.
     */
    fun open(c: Context, enc: String): JSONObject? = runCatching {
        val sealed = Base64.decode(enc, Base64.DEFAULT)
        val key = pushKey(c) ?: return null
        if (sealed.size < 12 + 16) return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, sealed, 0, 12))
        JSONObject(String(cipher.doFinal(sealed, 12, sealed.size - 12), Charsets.UTF_8))
    }.getOrNull()

    /** Actions for the app to replay, as the JSON the `device` function takes. */
    @Synchronized
    fun queue(c: Context, action: Map<String, String>) {
        val a = runCatching { JSONArray(prefs(c).getString("pending", "[]")) }.getOrDefault(JSONArray())
        a.put(JSONObject(action).toString())
        prefs(c).edit().putString("pending", a.toString()).commit()
    }

    @Synchronized
    fun takePending(c: Context): List<String> {
        val a = runCatching { JSONArray(prefs(c).getString("pending", "[]")) }.getOrDefault(JSONArray())
        prefs(c).edit().remove("pending").commit()
        return (0 until a.length()).map { a.getString(it) }
    }

    enum class Outcome { DONE, SIGNED_OUT, FAILED }

    /** POST to the `device` edge function (supabase/functions/device). Blocking: call it on [io]. */
    fun send(c: Context, action: Map<String, String>): Outcome {
        val token = token(c) ?: return Outcome.SIGNED_OUT
        val backend = backend(c) ?: return Outcome.SIGNED_OUT
        return try {
            val conn = URL("${backend.url}/functions/v1/device").openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.doOutput = true
                conn.setRequestProperty("content-type", "application/json")
                conn.setRequestProperty("apikey", backend.key)
                conn.setRequestProperty("x-dzep-token", token)
                conn.outputStream.use { it.write(JSONObject(action).toString().toByteArray()) }
                when (conn.responseCode) {
                    200, 201 -> Outcome.DONE
                    401 -> Outcome.SIGNED_OUT
                    else -> Outcome.FAILED
                }
            } finally {
                conn.disconnect()
            }
        } catch (e: Exception) {
            Outcome.FAILED
        }
    }

    /**
     * Ticks a todo off without the app (the Todos widget, a reminder's Done):
     * hides it from the widget at once, then tells the server; if that fails,
     * the app replays it (at once if it's running). [finished] runs after.
     */
    fun complete(c: Context, id: String, finished: () -> Unit = {}) {
        val app = c.applicationContext
        synchronized(this) {
            val todos = todos(app)
            if (setTodos(app, todos.filter { it.id != id })) TodosWidget.refresh(app)
        }
        io.execute {
            val action = mapOf("action" to "done", "id" to id)
            if (send(app, action) == Outcome.FAILED) {
                queue(app, action)
                NativeEvents.emit("pending")
            }
            finished()
        }
    }
}
