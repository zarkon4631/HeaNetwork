package io.github.zarkon4631.heanetwork.vpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.system.ErrnoException
import android.util.Log
import androidx.annotation.RequiresApi
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.StringIterator
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import io.nekohasekai.libbox.NetworkInterface as BoxInterface

private const val TAG = "HeaPlatform"

/** A Kotlin iterator handed to the core, which only walks it forward. */
class StringArray(private val iterator: Iterator<String>) : StringIterator {
    constructor(items: Iterable<String>) : this(items.iterator())

    override fun len(): Int = 0 // not used by the core
    override fun hasNext(): Boolean = iterator.hasNext()
    override fun next(): String = iterator.next()
}

class InterfaceArray(private val iterator: Iterator<BoxInterface>) : NetworkInterfaceIterator {
    override fun hasNext(): Boolean = iterator.hasNext()
    override fun next(): BoxInterface = iterator.next()
}

fun StringIterator.toList(): List<String> {
    val out = ArrayList<String>()
    while (hasNext()) out.add(next())
    return out
}

/**
 * Tracks the device's real (non-VPN) default network and reports it to the
 * core, which binds its outgoing sockets to it.
 *
 * The request-based registration follows shadowsocks-android and
 * sing-box-for-android (GPL-3.0): `registerDefaultNetworkCallback` reports
 * the VPN itself since Android 9, so the underlying network has to be
 * requested explicitly.
 */
object DefaultNetworkMonitor {
    @Volatile
    var defaultNetwork: Network? = null
        private set

    private var connectivity: ConnectivityManager? = null
    private var listener: InterfaceUpdateListener? = null
    private var registered = false

    private val handler by lazy {
        Handler(HandlerThread("hea-network").apply { start() }.looper)
    }

    private val request: NetworkRequest =
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            defaultNetwork = network
            notifyListener(network)
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            if (network == defaultNetwork) notifyListener(network)
        }

        override fun onLost(network: Network) {
            if (network == defaultNetwork) {
                defaultNetwork = null
                notifyListener(null)
            }
        }
    }

    @Synchronized
    fun start(context: Context) {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        connectivity = cm
        if (registered) return
        try {
            when {
                Build.VERSION.SDK_INT >= 31 ->
                    cm.registerBestMatchingNetworkCallback(request, callback, handler)
                Build.VERSION.SDK_INT >= 28 -> cm.requestNetwork(request, callback, handler)
                Build.VERSION.SDK_INT >= 26 -> cm.registerDefaultNetworkCallback(callback, handler)
                else -> cm.registerDefaultNetworkCallback(callback)
            }
            registered = true
        } catch (e: Exception) {
            Log.w(TAG, "network callback registration failed", e)
        }
        defaultNetwork = cm.activeNetwork
    }

    @Synchronized
    fun stop() {
        if (registered) {
            try {
                connectivity?.unregisterNetworkCallback(callback)
            } catch (e: Exception) {
                Log.w(TAG, "network callback unregistration failed", e)
            }
            registered = false
        }
        listener = null
        defaultNetwork = null
    }

    fun setListener(listener: InterfaceUpdateListener?) {
        this.listener = listener
        notifyListener(defaultNetwork)
    }

    fun networkFor(interfaceName: String): Network? {
        val cm = connectivity ?: return null
        @Suppress("DEPRECATION")
        return cm.allNetworks.firstOrNull {
            cm.getLinkProperties(it)?.interfaceName == interfaceName
        }
    }

    private fun notifyListener(network: Network?) {
        val listener = listener ?: return
        val cm = connectivity
        if (network == null || cm == null) {
            listener.updateDefaultInterface("", -1, false, false)
            return
        }
        // Link properties can lag behind the callback by a moment.
        repeat(10) {
            val name = cm.getLinkProperties(network)?.interfaceName
            val index = try {
                name?.let { NetworkInterface.getByName(it)?.index }
            } catch (e: Exception) {
                null
            }
            if (name != null && index != null) {
                listener.updateDefaultInterface(name, index, false, false)
                return
            }
            Thread.sleep(100)
        }
    }
}

/**
 * Resolves names with the system resolver of the underlying network, for
 * the core's `local` DNS server.
 */
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3
    private val executor = Executors.newCachedThreadPool()

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun network(): Network =
        DefaultNetworkMonitor.defaultNetwork ?: error("missing default interface")

    /** Runs an async resolver call to completion on the calling thread. */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun <T : Any> await(
        ctx: ExchangeContext,
        onAnswer: (T) -> Unit,
        start: (CancellationSignal, DnsResolver.Callback<T>) -> Unit,
    ) {
        val done = CountDownLatch(1)
        val signal = CancellationSignal()
        var failure: Throwable? = null
        ctx.onCancel {
            signal.cancel()
            done.countDown()
        }
        start(signal, object : DnsResolver.Callback<T> {
            override fun onAnswer(answer: T, rcode: Int) {
                if (rcode == 0) onAnswer(answer) else ctx.errorCode(rcode)
                done.countDown()
            }

            override fun onError(error: DnsResolver.DnsException) {
                val cause = error.cause
                if (cause is ErrnoException) {
                    ctx.errnoCode(cause.errno)
                } else {
                    failure = error
                }
                done.countDown()
            }
        })
        done.await()
        failure?.let { throw it }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = network()
        await<ByteArray>(ctx, { ctx.rawSuccess(it) }) { signal, callback ->
            DnsResolver.getInstance().rawQuery(
                network, message, DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
            )
        }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val default = network()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val answer = try {
                default.getAllByName(domain)
            } catch (e: UnknownHostException) {
                ctx.errorCode(RCODE_NXDOMAIN)
                return
            }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            return
        }
        val onAnswer: (Collection<InetAddress>) -> Unit = { answer ->
            ctx.success(answer.mapNotNull { it?.hostAddress }.joinToString("\n"))
        }
        val type = when {
            network.endsWith("4") -> DnsResolver.TYPE_A
            network.endsWith("6") -> DnsResolver.TYPE_AAAA
            else -> null
        }
        await(ctx, onAnswer) { signal, callback ->
            val resolver = DnsResolver.getInstance()
            if (type != null) {
                resolver.query(
                    default, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, callback,
                )
            } else {
                resolver.query(default, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
            }
        }
    }
}
