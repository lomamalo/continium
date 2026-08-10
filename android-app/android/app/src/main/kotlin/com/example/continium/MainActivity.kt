package com.example.continium

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "passerelle/box"
        private const val NOTIF_CHANNEL = "passerelle/box/status"
        private const val REQ_BLE = 1001
        private const val REQ_WIFI = 1002

        private val SVC_UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val RX_UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        private val TX_UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private lateinit var bluetoothManager: BluetoothManager
    private var adapter: BluetoothAdapter? = null
    private var gatt: BluetoothGatt? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var gattReady = false

    private val handler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var notifSink: EventChannel.EventSink? = null

    private var wifiManager: WifiManager? = null
    private var wifiPending: MethodChannel.Result? = null
    private var wifiScanReceiver: BroadcastReceiver? = null

    private var scanCallback: ScanCallback? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        adapter = bluetoothManager.adapter
        wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result -> onMethodCall(call, result) }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    notifSink = events
                }

                override fun onCancel(arguments: Any?) {
                    notifSink = null
                }
            })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> {
                val what = call.argument<String>("what") ?: "ble"
                ensurePermissions(what, result)
            }
            "scanBle" -> scanBle(result)
            "stopScanBle" -> stopScanBle(result)
            "connectBle" -> connectBle(call.argument<String>("address"), result)
            "disconnectBle" -> {
                disconnectBle()
                result.success(null)
            }
            "writeProvision" -> writeProvision(
                call.argument<String>("ssid") ?: "",
                call.argument<String>("password") ?: "",
                result,
            )
            "readProvisionStatus" -> readProvisionStatus(result)
            "gattState" -> result.success(gattState())
            "scanWifi" -> scanWifi(result)
            else -> result.notImplemented()
        }
    }

    /* ---------- runtime permissions ---------- */

    private fun ensurePermissions(what: String, result: MethodChannel.Result) {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            needed.add(Manifest.permission.BLUETOOTH_SCAN)
            needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            needed.add(Manifest.permission.BLUETOOTH)
            needed.add(Manifest.permission.BLUETOOTH_ADMIN)
        }
        if (what == "wifi") {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) {
            result.success(true)
            return
        }
        requestPermissions(
            missing.toTypedArray(),
            if (what == "wifi") REQ_WIFI else REQ_BLE,
        )
        // Result delivered in onRequestPermissionsResult (pending result kept).
        pendingPermissionResult = result
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        pendingPermissionResult?.success(grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        pendingPermissionResult = null
    }

    /* ---------- BLE scan ---------- */

    private fun scanBle(result: MethodChannel.Result) {
        val ble = adapter ?: return result.error("no_ble", "Bluetooth indisponible", null)
        if (!ble.isEnabled) return result.error("ble_off", "Bluetooth desactive", null)

        val callback = scanCallback
        if (callback != null) {
            handler.removeCallbacksAndMessages(null)
            ble.bluetoothLeScanner?.stopScan(callback)
            scanCallback = null
        }

        val devices = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                val name = device.name ?: ""
                if (device.address in seen) return
                seen.add(device.address)
                devices.add(
                    mapOf(
                        "name" to name,
                        "address" to device.address,
                        "rssi" to result.rssi,
                    ),
                )
            }

            override fun onScanFailed(errorCode: Int) {
                handler.removeCallbacksAndMessages(null)
                ble.bluetoothLeScanner?.stopScan(this)
                scanCallback = null
                result.success(devices)
            }
        }
        scanCallback = cb
        ble.bluetoothLeScanner?.startScan(cb)
        handler.postDelayed({
            ble.bluetoothLeScanner?.stopScan(cb)
            scanCallback = null
            result.success(devices)
        }, 8000)
    }

    private fun stopScanBle(result: MethodChannel.Result) {
        val callback = scanCallback
        if (callback != null) {
            handler.removeCallbacksAndMessages(null)
            adapter?.bluetoothLeScanner?.stopScan(callback)
            scanCallback = null
        }
        result.success(null)
    }

    /* ---------- GATT connection ---------- */

    private fun connectBle(address: String?, result: MethodChannel.Result) {
        if (address.isNullOrEmpty()) return result.error("bad_address", "Adresse manquante", null)
        val ble = adapter ?: return result.error("no_ble", "Bluetooth indisponible", null)
        val device = ble.getRemoteDevice(address)
        gattReady = false
        gatt = device.connectGatt(this, false, gattCallback)
        result.success(true)
    }

    private fun disconnectBle() {
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        txCharacteristic = null
        rxCharacteristic = null
        gattReady = false
        pendingWriteTimeout?.let { handler.removeCallbacks(it) }
        pendingWriteTimeout = null
        pendingWriteResult?.error("disconnected", "Boitier deconnecte", null)
        pendingWriteResult = null
        pendingReadResult?.success("err:disconnected")
        pendingReadResult = null
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gatt.requestMtu(256)
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                gattReady = false
                // Fail any pending operation: the box may have gone to sleep.
                pendingWriteTimeout?.let { handler.removeCallbacks(it) }
                pendingWriteTimeout = null
                pendingWriteResult?.error("disconnected", "Boitier deconnecte", null)
                pendingWriteResult = null
                pendingReadResult?.success("err:disconnected")
                pendingReadResult = null
                emitState("disconnected")
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            // nothing to do; discoverServices() was already issued
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                emitState("error:services")
                return
            }
            val svc = gatt.getService(SVC_UUID) ?: run {
                emitState("error:no-service")
                return
            }
            val rx = svc.getCharacteristic(RX_UUID)
            val tx = svc.getCharacteristic(TX_UUID)
            if (rx == null || tx == null) {
                emitState("error:no-chars")
                return
            }
            rxCharacteristic = rx
            txCharacteristic = tx
            val ok = gatt.setCharacteristicNotification(tx, true)
            val cccd = tx.getDescriptor(CCCD)
            cccd?.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            cccd?.let { gatt.writeDescriptor(it) }
            if (ok) {
                gattReady = true
                emitState("connected")
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            val value = characteristic.value?.toString(Charsets.UTF_8) ?: return
            emitNotify(value)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (characteristic.uuid == TX_UUID) {
                val value = characteristic.value?.toString(Charsets.UTF_8) ?: ""
                pendingReadResult?.success(value)
                pendingReadResult = null
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            pendingWriteTimeout?.let { handler.removeCallbacks(it) }
            pendingWriteTimeout = null
            val r = pendingWriteResult
            if (r != null) {
                r.success(status == BluetoothGatt.GATT_SUCCESS)
                pendingWriteResult = null
            }
        }
    }

    private var pendingWriteResult: MethodChannel.Result? = null
    private var pendingWriteTimeout: Runnable? = null
    private var pendingReadResult: MethodChannel.Result? = null

    private fun writeProvision(ssid: String, password: String, result: MethodChannel.Result) {
        val g = gatt ?: return result.error("no_gatt", "Non connecte", null)
        val rx = rxCharacteristic ?: return result.error("no_gatt", "Non connecte", null)
        val payload = "$ssid\n$password".toByteArray(Charsets.UTF_8)
        if (payload.size > 128) return result.error("too_long", "SSID/mot de passe trop long", null)
        pendingWriteResult = result
        pendingWriteTimeout?.let { handler.removeCallbacks(it) }
        val timeoutRunnable = Runnable {
            if (pendingWriteResult != null) {
                pendingWriteResult = null
                result.error("write_timeout", "Le boitier ne repond pas", null)
            }
        }
        pendingWriteTimeout = timeoutRunnable
        handler.postDelayed(timeoutRunnable, 10000)
        val queued = g.writeCharacteristic(rx, payload, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        if (queued != BluetoothGatt.GATT_SUCCESS) {            pendingWriteTimeout?.let { handler.removeCallbacks(it) }
            pendingWriteTimeout = null
            pendingWriteResult = null
            result.error("write_failed", "Ecriture BLE refusee", null)
        }
    }

    private fun readProvisionStatus(result: MethodChannel.Result) {
        val g = gatt ?: return result.error("no_gatt", "Non connecte", null)
        val tx = txCharacteristic ?: return result.error("no_gatt", "Non connecte", null)
        pendingReadResult = result
        g.readCharacteristic(tx)
    }

    private fun gattState(): Map<String, Any> = mapOf(
        "connected" to (gatt != null && gattReady),
        "device" to (gatt?.device?.address ?: ""),
    )

    /* ---------- WiFi scan ---------- */

    private fun scanWifi(result: MethodChannel.Result) {
        val wm = wifiManager ?: return result.error("no_wifi", "WiFi indisponible", null)
        if (!wm.isWifiEnabled) return result.error("wifi_off", "WiFi desactive", null)
        if (wifiPending != null) return result.error("busy", "Scan en cours", null)
        wifiPending = result

        wifiScanReceiver?.let { runCatching { unregisterReceiver(it) } }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != WifiManager.SCAN_RESULTS_AVAILABLE_ACTION) return
                handler.post {
                    val networks = mutableListOf<Map<String, Any>>()
                    val bySsid = mutableMapOf<String, Pair<Int, String>>() // ssid -> (level, bssid)
                    for (r in wm.scanResults) {
                        if (r.SSID.isNullOrEmpty()) continue
                        val prev = bySsid[r.SSID]
                        if (prev == null || r.level > prev.first) {
                            bySsid[r.SSID] = r.level to r.BSSID
                        }
                    }
                    for ((ssid, info) in bySsid.entries.sortedByDescending { it.value.first }) {
                        networks.add(mapOf("ssid" to ssid, "level" to info.first, "bssid" to info.second))
                    }
                    runCatching { unregisterReceiver(this) }
                    wifiPending?.success(networks)
                    wifiPending = null
                }
            }
        }
        wifiScanReceiver = receiver
        registerReceiver(receiver, IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION))
        val started = wm.startScan()
        if (!started) {
            runCatching { unregisterReceiver(receiver) }
            wifiPending?.error(
                "scan_failed",
                "startScan a echoue - active la localisation (reglages > position) puis reessaie",
                null,
            )
            wifiPending = null
        }
    }

    /* ---------- events to Flutter ---------- */

    private fun emitState(state: String) {
        handler.post {
            notifSink?.success(mapOf("event" to "state", "state" to state))
        }
    }

    private fun emitNotify(value: String) {
        handler.post {
            notifSink?.success(mapOf("event" to "notify", "value" to value))
        }
    }

    override fun onDestroy() {
        wifiScanReceiver?.let { runCatching { unregisterReceiver(it) } }
        disconnectBle()
        super.onDestroy()
    }
}
