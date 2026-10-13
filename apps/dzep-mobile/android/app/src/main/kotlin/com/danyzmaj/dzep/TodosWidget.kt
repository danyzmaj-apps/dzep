package com.danyzmaj.dzep

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import androidx.core.widget.RemoteViewsCompat

/** Opens the app at a dzep:// link (handled by app_links in lib/mobile.dart). */
fun openLink(c: Context, link: String): PendingIntent = PendingIntent.getActivity(
    c,
    link.hashCode(),
    Intent(Intent.ACTION_VIEW, Uri.parse(link), c, MainActivity::class.java)
        .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
)

/**
 * The open todos on the home screen (the iPhone's Todos widget,
 * ios/DzepWidget). The app keeps the snapshot current (setSharedTodos);
 * tapping a circle ticks that todo off right here, the app closed or not
 * (DzepShared.complete). + opens the add field as a todo; anywhere else opens
 * the Todos tab.
 */
class TodosWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) manager.updateAppWidget(id, views(c, id))
    }

    override fun onReceive(c: Context, intent: Intent) {
        if (intent.action == TICK) {
            val id = intent.getStringExtra(EXTRA_ID) ?: return
            val pending = goAsync()
            DzepShared.complete(c, id) { pending.finish() }
            return
        }
        super.onReceive(c, intent)
    }

    companion object {
        private const val TICK = "com.danyzmaj.dzep.TICK"
        private const val EXTRA_ID = "id"

        /** Redraws every Todos widget (the todos or the sign-in changed). */
        fun refresh(c: Context) {
            val manager = AppWidgetManager.getInstance(c)
            for (id in manager.getAppWidgetIds(ComponentName(c, TodosWidget::class.java))) {
                manager.updateAppWidget(id, views(c, id))
            }
        }

        private fun views(c: Context, widgetId: Int): RemoteViews {
            val todos = DzepShared.todos(c)
            val signedIn = DzepShared.token(c) != null
            val v = RemoteViews(c.packageName, R.layout.widget_todos)
            v.setOnClickPendingIntent(R.id.widget_root, openLink(c, "dzep://todos"))
            v.setOnClickPendingIntent(R.id.add, openLink(c, "dzep://add?kind=todo"))
            v.setTextViewText(R.id.count, if (todos.isEmpty()) "" else todos.size.toString())
            val message = when {
                !signedIn -> "Open Džep and sign in."
                todos.isEmpty() -> "All done 🎉"
                else -> null
            }
            v.setTextViewText(R.id.message, message ?: "")
            v.setViewVisibility(R.id.message, if (message == null) View.GONE else View.VISIBLE)
            v.setViewVisibility(R.id.list, if (message == null) View.VISIBLE else View.GONE)

            val items = RemoteViewsCompat.RemoteCollectionItems.Builder().setHasStableIds(true).setViewTypeCount(1)
            for (t in todos) {
                val row = RemoteViews(c.packageName, R.layout.widget_todo_item)
                row.setTextViewText(R.id.title, t.title)
                row.setOnClickFillInIntent(R.id.tick, Intent().putExtra(EXTRA_ID, t.id))
                items.addItem(t.id.hashCode().toLong(), row)
            }
            RemoteViewsCompat.setRemoteAdapter(c, v, widgetId, R.id.list, items.build())
            // Mutable: each row fills in its todo's id.
            v.setPendingIntentTemplate(
                R.id.list,
                PendingIntent.getBroadcast(
                    c,
                    0,
                    Intent(c, TodosWidget::class.java).setAction(TICK),
                    PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            return v
        }
    }
}
