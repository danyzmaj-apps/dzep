package com.danyzmaj.dzep

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.view.WindowManager
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Events for Dart (lib/native.dart's Native.listen) from wherever they
 * happen: the activity, a notification's Done, the widget, the push service.
 * Dropped while no engine runs; what matters then waits in DzepShared or in
 * [tappedTodo]/[tappedSession] for Dart to take.
 */
object NativeEvents {
    @Volatile
    var channel: MethodChannel? = null

    /** The todo whose reminder was tapped, until Dart takes it. */
    @Volatile
    var tappedTodo: String? = null

    /** The same for a terminal push: the omp session it is about. */
    @Volatile
    var tappedSession: String? = null

    private val main = Handler(Looper.getMainLooper())

    fun emit(method: String, args: Any? = null) {
        main.post { channel?.invokeMethod(method, args) }
    }
}

/**
 * Android's half of lib/native.dart (the iPhone's is
 * ios/Runner/AppDelegate.swift; same methods, arguments and results).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** Waiting for the notification permission's answer. */
    private val permissionWaiters = mutableListOf<(Boolean) -> Unit>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity has already handled its intent.
        if (savedInstanceState == null) tapped(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        tapped(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dzep/native")
        ch.setMethodCallHandler(::handle)
        channel = ch
        NativeEvents.channel = ch
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        if (NativeEvents.channel === channel) NativeEvents.channel = null
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** A reminder or a terminal push was tapped (dzep:// links go to app_links). */
    private fun tapped(intent: Intent?) {
        intent ?: return
        intent.getStringExtra(Notifications.EXTRA_TODO)?.let { id ->
            NativeEvents.tappedTodo = id
            NativeEvents.emit("openTodo", mapOf("id" to id))
            intent.removeExtra(Notifications.EXTRA_TODO)
        }
        if (intent.hasExtra(Notifications.EXTRA_SESSION)) {
            val session = intent.getStringExtra(Notifications.EXTRA_SESSION)
            NativeEvents.tappedSession = session
            NativeEvents.emit("openTerminal", session?.let { mapOf("session" to it) })
            intent.removeExtra(Notifications.EXTRA_SESSION)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
        when (call.method) {
            "setKeepAwake" -> {
                if (args["on"] == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            "deviceName" -> result.success(
                Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.ifBlank { null }
                    ?: Build.MODEL,
            )
            "setSharedToken" -> {
                val token = args["token"] as? String
                DzepShared.setToken(this, token)
                if (token == null) DzepShared.setTodos(this, emptyList())
                TodosWidget.refresh(this)
                result.success(null)
            }
            "setSharedTodos" -> {
                val todos = (args["todos"] as? List<*> ?: emptyList<Any>()).mapNotNull {
                    val t = it as? Map<*, *> ?: return@mapNotNull null
                    val id = t["id"] as? String ?: return@mapNotNull null
                    val title = t["title"] as? String ?: return@mapNotNull null
                    DzepShared.Todo(id, title)
                }
                if (DzepShared.setTodos(this, todos)) TodosWidget.refresh(this)
                result.success(null)
            }
            // Actions the widget or a reminder's Done couldn't send; the app replays them.
            "takePending" -> result.success(DzepShared.takePending(this))
            "getBackend" -> result.success(DzepShared.backend(this)?.let { mapOf("url" to it.url, "key" to it.key) })
            "setBackend" -> {
                val url = args["url"] as? String
                val key = args["key"] as? String
                DzepShared.setBackend(this, if (url != null && key != null) DzepShared.Backend(url, key) else null)
                result.success(null)
            }
            "setReminders" -> {
                val list = (args["reminders"] as? List<*> ?: emptyList<Any>()).filterIsInstance<Map<*, *>>()
                Reminders.schedule(this, list)
                // The first non-empty set asks for permission (once; Android remembers the answer).
                if (list.isNotEmpty()) askNotifications {}
                result.success(null)
            }
            "takeTappedTodo" -> {
                result.success(NativeEvents.tappedTodo)
                NativeEvents.tappedTodo = null
            }
            "takeTappedSession" -> {
                result.success(NativeEvents.tappedSession)
                NativeEvents.tappedSession = null
            }
            "registerPush" -> registerPush(result)
            "startActivity" -> askNotifications { result.success(OmpActivities.start(this, args)) }
            "updateActivity" -> result.success(OmpActivities.update(this, args))
            "endActivity" -> {
                (args["key"] as? String)?.let { OmpActivities.end(this, it, immediate = args["immediate"] == true) }
                result.success(null)
            }
            "liveActivities" -> result.success(OmpActivities.running(this))
            else -> result.notImplemented()
        }
    }

    /**
     * Permission first (a no-op after the first answer), then the FCM token.
     * Null: not allowed, no token, or a build without Firebase
     * (android/app/google-services.json); the app keeps local reminders then.
     */
    private fun registerPush(result: MethodChannel.Result) {
        if (FirebaseApp.getApps(this).isEmpty()) return result.success(null)
        askNotifications { granted ->
            if (!granted) return@askNotifications result.success(null)
            FirebaseMessaging.getInstance().token.addOnCompleteListener { task ->
                val token = if (task.isSuccessful) task.result else null
                if (token == null) return@addOnCompleteListener result.success(null)
                DzepShared.setFcmToken(this, token)
                val key = Base64.encodeToString(DzepShared.makePushKey(this), Base64.NO_WRAP)
                result.success(mapOf("token" to token, "key" to key))
            }
        }
    }

    /** Asks for POST_NOTIFICATIONS on Android 13+; [then] gets whether notifications can show. */
    private fun askNotifications(then: (Boolean) -> Unit) {
        Notifications.ensureChannels(this)
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            return then(Notifications.allowed(this))
        }
        permissionWaiters.add(then)
        if (permissionWaiters.size == 1) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATIONS_REQUEST)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATIONS_REQUEST) return
        val allowed = Notifications.allowed(this)
        val waiters = permissionWaiters.toList()
        permissionWaiters.clear()
        for (w in waiters) w(allowed)
    }

    private companion object {
        const val NOTIFICATIONS_REQUEST = 0x0D2E
    }
}
