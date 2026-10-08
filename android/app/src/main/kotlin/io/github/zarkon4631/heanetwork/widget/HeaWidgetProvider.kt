package io.github.zarkon4631.heanetwork.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import io.github.zarkon4631.heanetwork.MainActivity
import io.github.zarkon4631.heanetwork.R
import io.github.zarkon4631.heanetwork.vpn.HeaVpnService
import org.json.JSONObject
import java.io.File

/**
 * The home-screen widget: connect or disconnect, and step through the
 * saved configurations, without opening the app.
 *
 * The app (Dart side) keeps `files/widget/state.json` with the list of
 * configurations and the selected one, and a ready-to-run core config per
 * configuration in `files/widget/configs/<id>.json`. The widget only reads
 * those and writes back which one is selected.
 */
class HeaWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val TAG = "HeaWidget"
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

        private fun stateFile(context: Context) = File(context.filesDir, "widget/state.json")

        private fun configFile(context: Context, id: String) =
            File(context.filesDir, "widget/configs/$id.json")

        private class State(val json: JSONObject) {
            val ids = ArrayList<String>()
            val names = ArrayList<String>()

            init {
                val profiles = json.optJSONArray("profiles")
                if (profiles != null) {
                    for (i in 0 until profiles.length()) {
                        val p = profiles.optJSONObject(i) ?: continue
                        ids.add(p.optString("id"))
                        names.add(p.optString("name"))
                    }
                }
            }

            /** Index of the selected configuration, or -1 when there are none. */
            val index: Int
                get() {
                    if (ids.isEmpty()) return -1
                    val i = ids.indexOf(json.optString("selected"))
                    return if (i < 0) 0 else i
                }

            fun label(key: String, fallback: String): String =
                json.optJSONObject("labels")?.optString(key)?.takeIf { it.isNotEmpty() }
                    ?: fallback
        }

        private fun readState(context: Context): State {
            val json = try {
                JSONObject(stateFile(context).readText())
            } catch (e: Exception) {
                JSONObject()
            }
            return State(json)
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
                context, 10,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable,
            )
        }

        private fun render(context: Context): RemoteViews {
            val state = readState(context)
            val views = RemoteViews(context.packageName, R.layout.widget_hea)
            val status = HeaVpnService.status
            val index = state.index

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
                if (index < 0) {
                    state.label("empty", context.getString(R.string.widget_empty))
                } else {
                    state.names[index]
                },
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
                if (index < 0) openApp(context) else broadcast(context, ACTION_TOGGLE, 1),
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
        when (intent.action) {
            ACTION_TOGGLE -> toggle(context)
            ACTION_NEXT -> step(context, 1)
            ACTION_PREV -> step(context, -1)
            else -> return
        }
        refresh(context)
    }

    private fun toggle(context: Context) {
        if (HeaVpnService.status != HeaVpnService.STOPPED) {
            HeaVpnService.stop(context)
            return
        }
        connect(context, readState(context))
    }

    /** Starts the VPN with the selected configuration, or opens the app when
     *  that needs something only it can do (the VPN consent dialog). */
    private fun connect(context: Context, state: State) {
        val index = state.index
        val config = if (index < 0) null else configFile(context, state.ids[index])
        val ready = config != null && config.isFile && VpnService.prepare(context) == null
        if (!ready) {
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            )
            return
        }
        try {
            // Lets the app find the running core's control port afterwards.
            val active = JSONObject()
                .put("profileId", state.ids[index])
                .put("clashPort", state.json.optInt("clashPort"))
                .put("clashSecret", state.json.optString("clashSecret"))
            File(context.filesDir, "run").mkdirs()
            File(context.filesDir, "run/active.json").writeText(active.toString())
            HeaVpnService.start(context, config!!.readText())
        } catch (e: Exception) {
            Log.e(TAG, "could not start from the widget", e)
        }
    }

    private fun step(context: Context, delta: Int) {
        val state = readState(context)
        val count = state.ids.size
        if (count == 0) return
        val next = ((state.index + delta) % count + count) % count
        try {
            state.json.put("selected", state.ids[next])
            stateFile(context).writeText(state.json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "could not save the selection", e)
            return
        }
        // Switching while connected moves the connection to the new server.
        if (HeaVpnService.status == HeaVpnService.RUNNING) connect(context, readState(context))
    }
}
