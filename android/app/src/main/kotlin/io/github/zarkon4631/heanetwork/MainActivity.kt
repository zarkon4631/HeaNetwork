package io.github.zarkon4631.heanetwork

import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.github.zarkon4631.heanetwork.vpn.HeaVpnService
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private companion object {
        const val REQUEST_VPN = 4101
        const val REQUEST_NOTIFICATIONS = 4102
        const val ICON_SIZE = 96
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
            "installApk" -> installApk(call.argument<String>("path"), result)
            else -> result.notImplemented()
        }
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
