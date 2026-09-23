package com.example.app_movil_ia_local

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque

class MainActivity : FlutterActivity() {
    private val modelChannel = "drawschema.ai/model_assets"
    private val discoveryChannel = "drawschema.ai/backend_discovery"
    private var activeDiscovery: BackendDiscoverySession? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, modelChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "copyBundledModel") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val asset = call.argument<String>("asset")
                val fileName = call.argument<String>("fileName")
                if (asset.isNullOrBlank() || fileName.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Falta asset o fileName", null)
                    return@setMethodCallHandler
                }

                Thread {
                    try {
                        val modelDirectory = File(filesDir, "models").apply { mkdirs() }
                        val destination = File(modelDirectory, fileName)

                        if (!destination.exists() || destination.length() == 0L) {
                            val temporary = File(modelDirectory, "$fileName.part")
                            val assetKey = FlutterInjector.instance()
                                .flutterLoader()
                                .getLookupKeyForAsset(asset)

                            assets.open(assetKey).use { input ->
                                FileOutputStream(temporary).use { output ->
                                    input.copyTo(output, bufferSize = 1024 * 1024)
                                }
                            }

                            if (destination.exists()) destination.delete()
                            if (!temporary.renameTo(destination)) {
                                temporary.copyTo(destination, overwrite = true)
                                temporary.delete()
                            }
                        }

                        runOnUiThread { result.success(destination.absolutePath) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("MODEL_COPY_FAILED", error.message, null)
                        }
                    }
                }.start()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, discoveryChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "discoverBackends") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val timeoutMs = call.argument<Int>("timeoutMs")
                    ?.coerceIn(1_000, 15_000)
                    ?: 4_000

                activeDiscovery?.finish()
                activeDiscovery = BackendDiscoverySession(timeoutMs.toLong(), result).also {
                    it.start()
                }
            }
    }

    override fun onDestroy() {
        activeDiscovery?.finish()
        activeDiscovery = null
        super.onDestroy()
    }

    private inner class BackendDiscoverySession(
        private val timeoutMs: Long,
        private val result: MethodChannel.Result,
    ) {
        private val handler = Handler(Looper.getMainLooper())
        private val nsdManager = getSystemService(Context.NSD_SERVICE) as NsdManager
        private val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        private val multicastLock = wifiManager.createMulticastLock("drawschema-mdns").apply {
            setReferenceCounted(false)
        }
        private val pendingServices = ArrayDeque<NsdServiceInfo>()
        private val discovered = linkedMapOf<String, Map<String, Any>>()
        private var discoveryStarted = false
        private var resolving = false
        private var stopping = false
        private var completed = false

        private val hardFinish = Runnable { finish() }
        private val stopDiscovery = Runnable {
            if (completed) return@Runnable
            stopping = true
            stopNsdDiscovery()
            if (!resolving && pendingServices.isEmpty()) {
                finish()
            } else {
                handler.postDelayed(hardFinish, 750)
            }
        }

        private val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                discoveryStarted = true
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (completed || stopping) return
                if (!serviceInfo.serviceType.startsWith("_drawschema._tcp")) return
                if (discovered.containsKey(serviceInfo.serviceName)) return
                if (pendingServices.any { it.serviceName == serviceInfo.serviceName }) return

                pendingServices.add(serviceInfo)
                resolveNext()
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) {
                discoveryStarted = false
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                finish("No se pudo iniciar mDNS (código $errorCode)")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                discoveryStarted = false
                finish()
            }
        }

        fun start() {
            try {
                multicastLock.acquire()
                nsdManager.discoverServices(
                    "_drawschema._tcp.",
                    NsdManager.PROTOCOL_DNS_SD,
                    discoveryListener,
                )
                handler.postDelayed(stopDiscovery, timeoutMs)
            } catch (error: Exception) {
                finish(error.message ?: "No se pudo iniciar la búsqueda mDNS")
            }
        }

        @Suppress("DEPRECATION")
        private fun resolveNext() {
            if (completed || resolving) return
            val service = pendingServices.pollFirst()
            if (service == null) {
                if (stopping) finish()
                return
            }

            resolving = true
            nsdManager.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        resolving = false
                        resolveNext()
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val host = serviceInfo.host?.hostAddress?.substringBefore('%')
                        if (!host.isNullOrBlank() && serviceInfo.port > 0) {
                            val attributes = serviceInfo.attributes
                            val project = attributes["project"]?.toString(Charsets.UTF_8)
                                ?.takeIf { it.isNotBlank() }
                                ?: serviceInfo.serviceName
                            val schemaVersion = attributes["schemaVersion"]
                                ?.toString(Charsets.UTF_8)
                                .orEmpty()

                            discovered[serviceInfo.serviceName] = mapOf(
                                "serviceName" to serviceInfo.serviceName,
                                "project" to project,
                                "host" to host,
                                "port" to serviceInfo.port,
                                "schemaVersion" to schemaVersion,
                            )
                        }
                        resolving = false
                        resolveNext()
                    }
                },
            )
        }

        private fun stopNsdDiscovery() {
            if (!discoveryStarted) return
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (_: Exception) {
                // Android puede notificar que la búsqueda ya terminó.
            } finally {
                discoveryStarted = false
            }
        }

        fun finish(error: String? = null) {
            if (completed) return
            completed = true
            handler.removeCallbacks(stopDiscovery)
            handler.removeCallbacks(hardFinish)
            stopNsdDiscovery()
            if (multicastLock.isHeld) multicastLock.release()
            if (activeDiscovery === this) activeDiscovery = null

            if (error == null) {
                result.success(discovered.values.toList())
            } else {
                result.error("MDNS_DISCOVERY_FAILED", error, null)
            }
        }
    }
}
