package io.github.zarkon4631.heanetwork

import android.Manifest
import android.app.StatusBarManager
import android.app.UiModeManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.Configuration
import android.provider.Settings
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.zarkon4631.heanetwork.tile.HeaTileService
import io.github.zarkon4631.heanetwork.vpn.DefaultNetworkMonitor
import io.github.zarkon4631.heanetwork.vpn.HeaVpnService
import io.github.zarkon4631.heanetwork.widget.HeaWidgetProvider
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private companion object {
        const val REQUEST_VPN = 4101
        const val REQUEST_NOTIFICATIONS = 4102
        const val ICON_SIZE = 96

        /** What an address service answers with: one IPv4 or IPv6 address. */
        val ADDRESS = Regex("[0-9A-Fa-f:.]{7,45}")
    }

    private val background = Executors.newCachedThreadPool()
    private var pendingPrepare: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "hea/core").setMethodCallHandler(::onCoreCall)
        MethodChannel(messenger, "hea/apps").setMethodCallHandler(::onAppsCall)
        EventChannel(messenger, "hea/core/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    HeaVpnService.onStatus = { status, error ->
                        events.success(
                            mapOf("type" to "status", "status" to status, "error" to error),
                        )
                    }
                }

                override fun onCancel(arguments: Any?) {
                    HeaVpnService.onStatus = null
                }
            },
        )
    }

    private fun onCoreCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> prepareVpn(result)
            "start" -> {
                val config = call.argument<String>("config")
                if (config.isNullOrEmpty()) {
                    result.error("no-config", "empty configuration", null)
                } else {
                    HeaVpnService.start(this, config)
                    result.success(null)
                }
            }
            "stop" -> {
                HeaVpnService.stop(this)
                result.success(null)
            }
            "status" -> result.success(HeaVpnService.status)
            "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
            "device" -> result.success(deviceInfo())
            "refreshWidget" -> {
                HeaWidgetProvider.refresh(this)
                HeaTileService.refresh()
                result.success(null)
            }
            "addTile" -> addTile(result)
            "publicIp" -> {
                val urls = call.argument<List<String>>("urls").orEmpty()
                background.execute {
                    val ip = runCatching { publicIp(urls) }.getOrNull()
                    runOnUiThread { result.success(ip) }
                }
            }
            "installApk" -> installApk(call.argument<String>("path"), result)
            "tcpPing" -> {
                val host = call.argument<String>("host").orEmpty()
                val port = call.argument<Int>("port") ?: 0
                val timeout = call.argument<Int>("timeout") ?: 3000
                background.execute {
                    val ms = runCatching { tcpPing(host, port, timeout) }.getOrDefault(-1)
                    runOnUiThread { result.success(ms) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * The network that carries traffic when no VPN is involved. While a VPN
     * is up (ours or another app's) this app's own sockets go into it, and
     * a connection made through a tunnel is answered locally, so its timing
     * says nothing about the server.
     */
    private fun underlyingNetwork(): Network? {
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        fun isReal(network: Network): Boolean {
            val capabilities = cm.getNetworkCapabilities(network) ?: return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        // What the running VPN service itself sends its traffic through.
        DefaultNetworkMonitor.defaultNetwork?.takeIf { isReal(it) }?.let { return it }
        cm.activeNetwork?.takeIf { isReal(it) }?.let { return it }
        @Suppress("DEPRECATION")
        return cm.allNetworks.firstOrNull { isReal(it) }
    }

    /** Milliseconds to open one TCP connection; throws when it cannot be. */
    private fun connectTime(network: Network?, address: InetAddress, port: Int, timeoutMs: Int): Int {
        val socket = Socket()
        try {
            network?.bindSocket(socket)
            val started = SystemClock.elapsedRealtimeNanos()
            socket.connect(InetSocketAddress(address, port), timeoutMs)
            val elapsed = SystemClock.elapsedRealtimeNanos() - started
            return ((elapsed + 500_000L) / 1_000_000L).toInt().coerceAtLeast(1)
        } finally {
            runCatching { socket.close() }
        }
    }

    /**
     * Milliseconds to open a TCP connection to [host]:[port] over the real
     * network. Throws when the server cannot be reached.
     */
    private fun tcpPing(host: String, port: Int, timeoutMs: Int): Int {
        val network = underlyingNetwork()
        val addresses = network?.getAllByName(host) ?: InetAddress.getAllByName(host)
        val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.first()
        val first = connectTime(network, address, port, timeoutMs)
        // A second try smooths over one delayed packet; failing it is not
        // the server's fault.
        val second = runCatching { connectTime(network, address, port, timeoutMs) }
            .getOrDefault(first)
        return minOf(first, second)
    }

    /**
     * This device's address as the first of the address services at [urls]
     * to answer sees it. Asked over the real network: while the VPN is up
     * this app's own requests leave through the tunnel, and the answer
     * would be the VPN server's address.
     */
    private fun publicIp(urls: List<String>): String? {
        val network = underlyingNetwork()
        for (url in urls) {
            val answer = runCatching {
                val target = URL(url)
                val connection =
                    (network?.openConnection(target) ?: target.openConnection()) as HttpURLConnection
                try {
                    connection.connectTimeout = 2500
                    connection.readTimeout = 2500
                    connection.setRequestProperty("User-Agent", "HeaNetwork")
                    if (connection.responseCode != 200) {
                        null
                    } else {
                        connection.inputStream.bufferedReader().use { it.readLine() }?.trim()
                    }
                } finally {
                    connection.disconnect()
                }
            }.getOrNull()
            if (answer != null && ADDRESS.matches(answer)) return answer
        }
        return null
    }

    /**
     * Offers to put the connect tile into the quick settings panel. Android
     * has a prompt for that since 13; before it the user drags the tile in
     * by hand, which the app then explains.
     */
    private fun addTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) {
            result.success("manual")
            return
        }
        try {
            getSystemService(StatusBarManager::class.java).requestAddTileService(
                ComponentName(this, HeaTileService::class.java),
                getString(R.string.app_name),
                Icon.createWithResource(this, R.drawable.ic_tile),
                mainExecutor,
            ) { code ->
                result.success(
                    when (code) {
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already"
                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "declined"
                        // The system could not show its prompt.
                        else -> "manual"
                    },
                )
            }
        } catch (e: Exception) {
            result.success("manual")
        }
    }

    /**
     * What the app tells a subscription server about this device, and
     * whether it is a TV (which changes the layout).
     */
    private fun deviceInfo(): Map<String, Any?> {
        val uiMode = getSystemService(UI_MODE_SERVICE) as UiModeManager
        val tv = uiMode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        return mapOf(
            "id" to Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID),
            "release" to Build.VERSION.RELEASE,
            "model" to listOf(Build.MANUFACTURER, Build.MODEL)
                .filter { !it.isNullOrBlank() }
                .joinToString(" "),
            "tv" to tv,
        )
    }

    /** Shows the system's VPN consent dialog when it has not been given yet. */
    private fun prepareVpn(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            // Only so the "connected" notification is visible; the answer
            // does not gate the connection.
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingPrepare?.success(false)
        pendingPrepare = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_VPN)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(resultCode == RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        val file = path?.let(::File)
        if (file == null || !file.isFile) {
            result.error("no-file", "update file not found", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.success(null)
        } catch (e: Exception) {
            result.error("install-failed", e.message, null)
        }
    }

    private fun onAppsCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> background.execute {
                val apps = runCatching { listApps() }
                runOnUiThread {
                    apps.fold(result::success) { result.error("list-failed", it.message, null) }
                }
            }
            "icon" -> {
                val name = call.argument<String>("package")
                background.execute {
                    val png = runCatching { name?.let(::appIcon) }.getOrNull()
                    runOnUiThread { result.success(png) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Installed apps that can use the network, without this app itself. */
    private fun listApps(): List<Map<String, Any?>> {
        val pm = packageManager
        @Suppress("DEPRECATION")
        return pm.getInstalledApplications(0)
            .filter { it.packageName != packageName }
            .filter {
                pm.checkPermission(Manifest.permission.INTERNET, it.packageName) ==
                    PackageManager.PERMISSION_GRANTED
            }
            .map {
                val system = it.flags and ApplicationInfo.FLAG_SYSTEM != 0 &&
                    it.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP == 0
                mapOf(
                    "package" to it.packageName,
                    "label" to pm.getApplicationLabel(it).toString(),
                    "system" to system,
                )
            }
    }

    private fun appIcon(name: String): ByteArray {
        val drawable = packageManager.getApplicationIcon(name)
        val bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE)
        drawable.draw(canvas)
        return ByteArrayOutputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
            it.toByteArray()
        }
    }

    override fun onDestroy() {
        background.shutdown()
        super.onDestroy()
    }
}
