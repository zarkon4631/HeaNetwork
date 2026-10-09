package io.github.zarkon4631.heanetwork.vpn

import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.util.Log
import io.github.zarkon4631.heanetwork.MainActivity
import org.json.JSONObject
import java.io.File

/**
 * Connecting without the app's interface: what the home-screen widget and
 * the quick settings tile have in common.
 *
 * The app (Dart side) keeps `files/widget/state.json` with the list of
 * configurations and the selected one, and a ready-to-run core config per
 * configuration in `files/widget/configs/<id>.json`. This object only reads
 * those and writes back which one is selected.
 */
object QuickConnect {
    private const val TAG = "HeaQuickConnect"

    class State(val json: JSONObject) {
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

        /** Name of the selected configuration, or null when there are none. */
        val selectedName: String?
            get() = names.getOrNull(index)

        fun label(key: String, fallback: String): String =
            json.optJSONObject("labels")?.optString(key)?.takeIf { it.isNotEmpty() }
                ?: fallback
    }

    private fun stateFile(context: Context) = File(context.filesDir, "widget/state.json")

    private fun configFile(context: Context, id: String) =
        File(context.filesDir, "widget/configs/$id.json")

    fun readState(context: Context): State {
        val json = try {
            JSONObject(stateFile(context).readText())
        } catch (e: Exception) {
            JSONObject()
        }
        return State(json)
    }

    /** Brings up the app's window. */
    fun appIntent(context: Context): Intent =
        Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    /**
     * Starts the VPN with the selected configuration. Returns false when
     * that needs something only the app can do: there is no configuration
     * yet, or the system's VPN consent has not been given.
     */
    fun connect(context: Context): Boolean {
        val state = readState(context)
        val index = state.index
        val config = if (index < 0) null else configFile(context, state.ids[index])
        if (config == null || !config.isFile || VpnService.prepare(context) != null) {
            return false
        }
        try {
            // Lets the app find the running core's control port afterwards.
            val active = JSONObject()
                .put("profileId", state.ids[index])
                .put("clashPort", state.json.optInt("clashPort"))
                .put("clashSecret", state.json.optString("clashSecret"))
            File(context.filesDir, "run").mkdirs()
            File(context.filesDir, "run/active.json").writeText(active.toString())
            HeaVpnService.start(context, config.readText())
        } catch (e: Exception) {
            Log.e(TAG, "could not start the VPN", e)
        }
        return true
    }

    /**
     * Connects, or disconnects, which also calls off a connection that is
     * still being set up. Returns false as [connect] does.
     */
    fun toggle(context: Context): Boolean {
        if (HeaVpnService.status != HeaVpnService.STOPPED) {
            HeaVpnService.stop(context)
            return true
        }
        return connect(context)
    }

    /**
     * Moves the selection [delta] configurations along the list. Switching
     * while connected moves the connection to the new server. Returns false
     * as [connect] does.
     */
    fun step(context: Context, delta: Int): Boolean {
        val state = readState(context)
        val count = state.ids.size
        if (count == 0) return true
        val next = ((state.index + delta) % count + count) % count
        try {
            state.json.put("selected", state.ids[next])
            stateFile(context).writeText(state.json.toString())
        } catch (e: Exception) {
            Log.e(TAG, "could not save the selection", e)
            return true
        }
        return HeaVpnService.status != HeaVpnService.RUNNING || connect(context)
    }
}
