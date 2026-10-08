package io.github.zarkon4631.heanetwork.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.zarkon4631.heanetwork.MainActivity
import io.github.zarkon4631.heanetwork.R
import io.nekohasekai.libbox.BridgeOptions
import io.nekohasekai.libbox.BridgeSession
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.PlatformUser
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.ShellSession
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors
import io.nekohasekai.libbox.NetworkInterface as BoxInterface
import io.nekohasekai.libbox.Notification as BoxNotification

/**
 * Runs the sing-box core inside a VPN service. The core asks this class for
 * everything that needs Android: the tun device, the underlying network,
 * which app owns a connection.
 *
 * The structure follows sing-box-for-android (GPL-3.0).
 */
class HeaVpnService : VpnService(), PlatformInterface, CommandServerHandler {

    companion object {
        private const val TAG = "HeaVpnService"
        private const val ACTION_START = "io.github.zarkon4631.heanetwork.START"
        private const val ACTION_STOP = "io.github.zarkon4631.heanetwork.STOP"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 1

        const val STOPPED = "stopped"
        const val STARTING = "starting"
        const val RUNNING = "running"
        const val STOPPING = "stopping"

        @Volatile
        var status: String = STOPPED
            private set

        /** Receives every status change on the main thread. */
        @Volatile
        var onStatus: ((status: String, error: String?) -> Unit)? = null

        // Handed over outside the Intent: a config can exceed what a Binder
        // transaction carries.
        @Volatile
        private var pendingConfig: String? = null

        private val main = Handler(Looper.getMainLooper())
        private var libboxReady = false

        fun start(context: Context, config: String) {
            pendingConfig = config
            ContextCompat.startForegroundService(
                context,
                Intent(context, HeaVpnService::class.java).setAction(ACTION_START),
            )
        }

        fun stop(context: Context) {
            if (status == STOPPED) return
            context.startService(
                Intent(context, HeaVpnService::class.java).setAction(ACTION_STOP),
            )
        }

        private fun publish(newStatus: String, error: String? = null) {
            status = newStatus
            main.post { onStatus?.invoke(newStatus, error) }
        }

        @Synchronized
        private fun setupLibbox(context: Context) {
            if (libboxReady) return
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            Libbox.setup(SetupOptions().also {
                it.basePath = context.filesDir.path
                it.workingPath = (context.getExternalFilesDir(null) ?: context.filesDir).path
                it.tempPath = context.cacheDir.path
                // Works around golang/go#68760 on the affected releases.
                it.fixAndroidStack = Build.VERSION.SDK_INT in 24..25 || Build.VERSION.SDK_INT >= 28
                it.logMaxLines = 3000
                it.debug = false
                it.crashReportSource = "HeaNetwork"
                it.appVersion = info.versionName ?: ""
                it.appMarketingVersion = info.versionName ?: ""
            })
            libboxReady = true
        }
    }

    /** Serialises start and stop so they can never interleave. */
    private val worker = Executors.newSingleThreadExecutor()
    private var commandServer: CommandServer? = null
    private var tun: ParcelFileDescriptor? = null

    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }

    // ---- service lifecycle ------------------------------------------------

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> shutdown(null)
            else -> {
                val config = pendingConfig
                pendingConfig = null
                if (config == null || status != STOPPED) {
                    // Restarted by the system without a config, or a duplicate start.
                    if (status == STOPPED) stopSelf()
                    return START_NOT_STICKY
                }
                publish(STARTING)
                goForeground()
                worker.execute { startCore(config) }
            }
        }
        return START_NOT_STICKY
    }

    override fun onRevoke() = shutdown(null)

    override fun onDestroy() {
        if (status != STOPPED) shutdown(null)
        super.onDestroy()
    }

    private fun startCore(config: String) {
        try {
            setupLibbox(this)
            DefaultNetworkMonitor.start(this)
            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            server.startOrReloadService(config, OverrideOptions())
            publish(RUNNING)
        } catch (e: Throwable) {
            Log.e(TAG, "core failed to start", e)
            teardown()
            publish(STOPPED, e.message ?: e.toString())
            main.post { stopForegroundAndSelf() }
        }
    }

    private fun shutdown(error: String?) {
        if (status == STOPPED || status == STOPPING) return
        publish(STOPPING)
        worker.execute {
            teardown()
            publish(STOPPED, error)
            main.post { stopForegroundAndSelf() }
        }
    }

    private fun teardown() {
        runCatching { tun?.close() }
        tun = null
        runCatching { DefaultNetworkMonitor.stop() }
        commandServer?.let { server ->
            runCatching { server.closeService() }
                .onFailure { Log.w(TAG, "closeService", it) }
            runCatching { server.close() }
        }
        commandServer = null
    }

    private fun stopForegroundAndSelf() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun goForeground() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL, getString(R.string.vpn_channel), NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val immutable = if (Build.VERSION.SDK_INT >= 23) PendingIntent.FLAG_IMMUTABLE else 0
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable,
        )
        val stop = PendingIntent.getService(
            this, 1,
            Intent(this, HeaVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable,
        )
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.vpn_running))
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(open)
            .addAction(0, getString(R.string.vpn_disconnect), stop)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // ---- CommandServerHandler ---------------------------------------------

    override fun serviceStop() = shutdown(null)

    override fun serviceReload() {}

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()

    override fun setSystemProxyEnabled(enabled: Boolean) {}

    override fun triggerNativeCrash() {}

    override fun writeDebugMessage(message: String?) {
        Log.d(TAG, message ?: "")
    }

    override fun connectSSHAgent(): Int = -1

    // ---- PlatformInterface: networking ------------------------------------

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    /** Keeps the core's own sockets out of the tunnel it provides. */
    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun bindInterfaceControl(fd: Int, interfaceName: String?) {
        protect(fd)
        val network = interfaceName?.let { DefaultNetworkMonitor.networkFor(it) } ?: return
        ParcelFileDescriptor.fromFd(fd).use { network.bindSocket(it.fileDescriptor) }
    }

    override fun openTun(options: TunOptions?): Int {
        options ?: error("android: missing tun options")
        if (prepare(this) != null) error("android: missing VPN permission")

        val builder = Builder().setSession(getString(R.string.app_name)).setMtu(options.mtu)
        if (Build.VERSION.SDK_INT >= 29) builder.setMetered(false)

        val inet4 = options.inet4Address
        var hasInet4 = false
        while (inet4.hasNext()) {
            val a = inet4.next()
            builder.addAddress(a.address(), a.prefix())
            hasInet4 = true
        }
        val inet6 = options.inet6Address
        var hasInet6 = false
        while (inet6.hasNext()) {
            val a = inet6.next()
            builder.addAddress(a.address(), a.prefix())
            hasInet6 = true
        }

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dns = options.dnsServerAddress
                while (dns.hasNext()) builder.addDnsServer(dns.next())
            }

            if (Build.VERSION.SDK_INT >= 33) {
                val route4 = options.inet4RouteAddress
                if (route4.hasNext()) {
                    while (route4.hasNext()) builder.addRoute(route4.next().toIpPrefix())
                } else if (hasInet4) {
                    builder.addRoute("0.0.0.0", 0)
                }
                val route6 = options.inet6RouteAddress
                if (route6.hasNext()) {
                    while (route6.hasNext()) builder.addRoute(route6.next().toIpPrefix())
                } else if (hasInet6) {
                    builder.addRoute("::", 0)
                }
                val exclude4 = options.inet4RouteExcludeAddress
                while (exclude4.hasNext()) builder.excludeRoute(exclude4.next().toIpPrefix())
                val exclude6 = options.inet6RouteExcludeAddress
                while (exclude6.hasNext()) builder.excludeRoute(exclude6.next().toIpPrefix())
            } else {
                // No route exclusion before Android 13; the core pre-computes
                // the ranges to route instead.
                val range4 = options.inet4RouteRange
                while (range4.hasNext()) {
                    val r = range4.next()
                    builder.addRoute(r.address(), r.prefix())
                }
                val range6 = options.inet6RouteRange
                while (range6.hasNext()) {
                    val r = range6.next()
                    builder.addRoute(r.address(), r.prefix())
                }
            }

            // Per-app routing. An excluded app does not see the VPN at all.
            val include = options.includePackage
            while (include.hasNext()) {
                val name = include.next()
                try {
                    builder.addAllowedApplication(name)
                } catch (e: PackageManager.NameNotFoundException) {
                    Log.w(TAG, "allowed app is not installed: $name")
                }
            }
            val exclude = options.excludePackage
            while (exclude.hasNext()) {
                val name = exclude.next()
                try {
                    builder.addDisallowedApplication(name)
                } catch (e: PackageManager.NameNotFoundException) {
                    Log.w(TAG, "excluded app is not installed: $name")
                }
            }
        }

        val pfd = builder.establish()
            ?: error("android: the VPN permission was revoked or another VPN is always-on")
        tun = pfd
        return pfd.fd
    }

    private fun io.nekohasekai.libbox.RoutePrefix.toIpPrefix(): IpPrefix {
        check(Build.VERSION.SDK_INT >= 33)
        return IpPrefix(InetAddress.getByName(address()), prefix())
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < 29

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String?,
        sourcePort: Int,
        destinationAddress: String?,
        destinationPort: Int,
    ): ConnectionOwner {
        check(Build.VERSION.SDK_INT >= 29) { "android: connection owner needs Android 10" }
        val uid = connectivity.getConnectionOwnerUid(
            ipProtocol,
            InetSocketAddress(sourceAddress, sourcePort),
            InetSocketAddress(destinationAddress, destinationPort),
        )
        if (uid == Process.INVALID_UID) error("android: connection owner not found")
        val packages = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().also {
            it.userId = uid
            it.userName = packages.firstOrNull() ?: ""
            it.setAndroidPackageNames(StringArray(packages))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        DefaultNetworkMonitor.setListener(listener)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        DefaultNetworkMonitor.setListener(null)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val system = NetworkInterface.getNetworkInterfaces().toList()
        val result = ArrayList<BoxInterface>()
        @Suppress("DEPRECATION")
        for (network in connectivity.allNetworks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val caps = connectivity.getNetworkCapabilities(network) ?: continue
            val iface = system.find { it.name == link.interfaceName } ?: continue
            val box = BoxInterface()
            box.name = link.interfaceName
            box.index = iface.index
            runCatching { box.mtu = iface.mtu }
            box.dnsServer = StringArray(link.dnsServers.mapNotNull { it.hostAddress })
            box.gateway = StringArray(
                link.routes
                    .filter { it.destination.prefixLength == 0 }
                    .mapNotNull { it.gateway }
                    .filterNot { it.isAnyLocalAddress }
                    .mapNotNull { it.hostAddress },
            )
            box.type = when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                else -> Libbox.InterfaceTypeOther
            }
            box.addresses = StringArray(
                iface.interfaceAddresses.map { a ->
                    val address = a.address
                    val host = if (address is Inet6Address) {
                        // Drops the %scope suffix the core cannot parse.
                        Inet6Address.getByAddress(address.address).hostAddress
                    } else {
                        address.hostAddress
                    }
                    "$host/${a.networkPrefixLength}"
                },
            )
            var flags = 0
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                flags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (iface.isLoopback) flags = flags or OsConstants.IFF_LOOPBACK
            if (iface.isPointToPoint) flags = flags or OsConstants.IFF_POINTOPOINT
            if (iface.supportsMulticast()) flags = flags or OsConstants.IFF_MULTICAST
            box.flags = flags
            box.metered = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            result.add(box)
        }
        return InterfaceArray(result.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {}

    // Wi-Fi based rules are not offered by this client, so the location
    // permission reading the SSID would need is never requested.
    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport = LocalResolver

    override fun registerMyInterface(name: String?) {}

    // ---- PlatformInterface: notifications from the core -------------------

    override fun sendNotification(notification: BoxNotification?) {
        notification ?: return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = "core-${notification.typeID}"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    channel, notification.typeName, NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val built = NotificationCompat.Builder(this, channel)
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(notification.identifier, notification.typeID, built) }
    }

    override fun cancelNotification(identifier: String?, typeID: Int) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(identifier, typeID)
    }

    // ---- PlatformInterface: features this client does not use -------------
    // They back the core's SSH server, Tailscale and bridge endpoints, which
    // need root on Android.

    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun usePlatformShell(): Boolean = false

    override fun checkPlatformShell() {
        error("not supported")
    }

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): ShellSession = error("not supported")

    override fun lookupUser(username: String?): PlatformUser = error("not supported")

    override fun lookupSFTPServer(): String = error("not supported")

    override fun readSystemSSHHostKey(): String = error("not supported")

    override fun tailscaleHostname(): String = "${Build.MANUFACTURER} ${Build.MODEL}"

    override fun usePlatformBridge(): Boolean = false

    override fun createBridge(options: BridgeOptions?): BridgeSession = error("not supported")
}
