package io.github.zarkon4631.heanetwork.tile

import android.app.PendingIntent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import io.github.zarkon4631.heanetwork.R
import io.github.zarkon4631.heanetwork.vpn.HeaVpnService
import io.github.zarkon4631.heanetwork.vpn.QuickConnect

/**
 * The quick settings tile: connect or disconnect with one tap in the panel
 * that a swipe down from the top of the screen opens, without opening the
 * app. It runs on the same exported configurations as the home-screen
 * widget (see [QuickConnect]).
 */
class HeaTileService : TileService() {

    companion object {
        // The system keeps this service bound only while the tile is on
        // screen, and only then is there anything to redraw.
        @Volatile
        private var listening: HeaTileService? = null

        /** Redraws the tile if it is on screen; called on each VPN status change. */
        fun refresh() {
            listening?.render()
        }
    }

    override fun onStartListening() {
        listening = this
        render()
    }

    override fun onStopListening() {
        if (listening === this) listening = null
    }

    override fun onClick() {
        if (QuickConnect.toggle(this)) {
            render()
            return
        }
        // No configuration yet, or no VPN consent: the app sorts out both.
        if (isLocked) unlockAndRun { openApp() } else openApp()
    }

    private fun openApp() {
        val intent = QuickConnect.appIntent(this)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, 20, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ),
            )
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }

    private fun render() {
        val tile = qsTile ?: return
        val status = HeaVpnService.status
        val state = QuickConnect.readState(this)
        // Shown under the label: the server a tap connects to, or is using.
        val detail = when (status) {
            HeaVpnService.STARTING, HeaVpnService.STOPPING ->
                state.label("connecting", getString(R.string.widget_connecting))
            HeaVpnService.RUNNING ->
                state.selectedName
                    ?: state.label("connected", getString(R.string.vpn_running))
            else ->
                state.selectedName ?: state.label("empty", getString(R.string.widget_empty))
        }
        tile.state =
            if (status == HeaVpnService.STOPPED) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.label = getString(R.string.app_name)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile)
        if (Build.VERSION.SDK_INT >= 29) tile.subtitle = detail
        tile.contentDescription = "${getString(R.string.app_name)}, $detail"
        tile.updateTile()
    }
}
