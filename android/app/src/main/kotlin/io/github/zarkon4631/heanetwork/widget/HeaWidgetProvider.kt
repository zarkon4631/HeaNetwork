package io.github.zarkon4631.heanetwork.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import io.github.zarkon4631.heanetwork.R
import io.github.zarkon4631.heanetwork.vpn.HeaVpnService
import io.github.zarkon4631.heanetwork.vpn.QuickConnect

/**
 * The home-screen widget: connect or disconnect, and step through the
 * saved configurations, without opening the app. The connecting itself is
 * [QuickConnect]'s, shared with the quick settings tile.
 */
class HeaWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_TOGGLE = "io.github.zarkon4631.heanetwork.widget.TOGGLE"
        private const val ACTION_NEXT = "io.github.zarkon4631.heanetwork.widget.NEXT"
        private const val ACTION_PREV = "io.github.zarkon4631.heanetwork.widget.PREV"

        /** Redraws every placed widget; called on each VPN status change. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, HeaWidgetProvider::class.java),
            )
            if (ids.isEmpty()) return
            val views = render(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        private fun broadcast(context: Context, action: String, code: Int): PendingIntent {
            val immutable = if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
            return PendingIntent.getBroadcast(
                context, code,
                Intent(context, HeaWidgetProvider::class.java).setAction(action),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable,
            )
        }

        private fun openApp(context: Context): PendingIntent {
            val immutable = if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
            return PendingIntent.getActivity(
                context, 10, QuickConnect.appIntent(context),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable,
            )
        }

        private fun render(context: Context): RemoteViews {
            val state = QuickConnect.readState(context)
            val views = RemoteViews(context.packageName, R.layout.widget_hea)
            val status = HeaVpnService.status

            val statusText = when (status) {
                HeaVpnService.RUNNING ->
                    state.label("connected", context.getString(R.string.vpn_running))
                HeaVpnService.STARTING, HeaVpnService.STOPPING ->
                    state.label("connecting", context.getString(R.string.widget_connecting))
                else -> state.label("disconnected", context.getString(R.string.widget_off))
            }
            views.setTextViewText(R.id.widget_status, statusText)
            views.setTextViewText(
                R.id.widget_name,
                state.selectedName
                    ?: state.label("empty", context.getString(R.string.widget_empty)),
            )
            views.setInt(
                R.id.widget_toggle, "setBackgroundResource",
                when (status) {
                    HeaVpnService.RUNNING -> R.drawable.widget_btn_on
                    HeaVpnService.STOPPED -> R.drawable.widget_btn_off
                    else -> R.drawable.widget_btn_busy
                },
            )

            // Without a configuration the only useful action is opening the app.
            views.setOnClickPendingIntent(
                R.id.widget_toggle,
                if (state.index < 0) openApp(context) else broadcast(context, ACTION_TOGGLE, 1),
            )
            views.setOnClickPendingIntent(R.id.widget_prev, broadcast(context, ACTION_PREV, 2))
            views.setOnClickPendingIntent(R.id.widget_next, broadcast(context, ACTION_NEXT, 3))
            views.setOnClickPendingIntent(R.id.widget_text, openApp(context))
            return views
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = render(context)
        for (id in ids) manager.updateAppWidget(id, views)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val done = when (intent.action) {
            ACTION_TOGGLE -> QuickConnect.toggle(context)
            ACTION_NEXT -> QuickConnect.step(context, 1)
            ACTION_PREV -> QuickConnect.step(context, -1)
            else -> return
        }
        // What the widget cannot do itself (the VPN consent dialog) the app does.
        if (!done) context.startActivity(QuickConnect.appIntent(context))
        refresh(context)
    }
}
