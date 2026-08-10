import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// BLE + WiFi provisioning of the box (ESP32), driven from the phone:
/// scan for the box over BLE, connect, send the WiFi credentials, then
/// the box connects to the home WiFi and syncs with the daemon on battery.
/// Everything is implemented natively in Kotlin (MainActivity) -- no
/// third-party BLE dependency (offline environment).
class BoxProvisioningService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('passerelle/box');
  static const EventChannel _notifChannel = EventChannel('passerelle/box/status');

  /// BLE/WiFi provisioning only exists on Android (native Kotlin side);
  /// on Linux/desktop there is no platform implementation.
  static bool get supported => defaultTargetPlatform == TargetPlatform.android;

  final List<BleDevice> _bleDevices = [];
  List<BleDevice> get bleDevices => List.unmodifiable(_bleDevices);

  final List<WifiNetwork> _wifiNetworks = [];
  List<WifiNetwork> get wifiNetworks => List.unmodifiable(_wifiNetworks);

  bool _bleConnected = false;
  bool get bleConnected => _bleConnected;

  String? _lastError;
  String? get lastError => _lastError;

  String? _provisionResult;
  String? get provisionResult => _provisionResult;

  bool _scanningBle = false;
  bool get scanningBle => _scanningBle;

  bool _scanningWifi = false;
  bool get scanningWifi => _scanningWifi;

  StreamSubscription? _notifSub;
  Completer<String>? _notifyWaiter;

  void init() {
    if (!supported) return;
    _notifSub ??= _notifChannel.receiveBroadcastStream().listen(_onEvent);
  }

  void _onEvent(dynamic raw) {
    final data = (raw as Map<dynamic, dynamic>?)?.cast<String, dynamic>() ?? const {};
    switch (data['event']) {
      case 'state':
        _bleConnected = data['state'] == 'connected';
        if (!_bleConnected) {
          // The box went to sleep / dropped: fail any pending provision.
          final w = _notifyWaiter;
          if (w != null && !w.isCompleted) w.complete('err:disconnected');
          _notifyWaiter = null;
        }
        notifyListeners();
      case 'notify':
        final value = data['value']?.toString() ?? '';
        _provisionResult = value;
        _notifyWaiter?.complete(value);
        _notifyWaiter = null;
        notifyListeners();
    }
  }

  /// Requests the runtime permissions needed for BLE ("ble") or BLE+WiFi
  /// scan ("wifi"). Returns true once everything is granted.
  Future<bool> ensurePermissions({String what = 'ble'}) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('ensurePermissions', {'what': what}) ?? false;
    } on PlatformException catch (e) {
      _lastError = e.message;
      notifyListeners();
      return false;
    } on MissingPluginException {
      _lastError = 'Provisioning non supporte sur cette plateforme';
      notifyListeners();
      return false;
    }
  }

  /// Scans for BLE peripherals for ~8s; results accumulate in [bleDevices].
  Future<void> scanBle() async {
    if (!supported) {
      _lastError = 'Provisioning non supporte sur cette plateforme';
      return;
    }
    _scanningBle = true;
    _bleDevices.clear();
    _lastError = null;
    notifyListeners();
    try {
      final list = await _channel.invokeListMethod<dynamic>('scanBle');
      _bleDevices
        ..clear()
        ..addAll(
          (list ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => BleDevice.fromJson(e.cast<String, dynamic>())),
        );
    } on PlatformException catch (e) {
      _lastError = e.message;
    } finally {
      _scanningBle = false;
      notifyListeners();
    }
  }

  Future<void> connectBle(String address) async {
    if (!supported) return;
    _lastError = null;
    try {
      await _channel.invokeMethod('connectBle', {'address': address});
    } on PlatformException catch (e) {
      _lastError = e.message;
    }
    notifyListeners();
  }

  Future<void> disconnectBle() async {
    if (!supported) return;
    await _channel.invokeMethod('disconnectBle');
    _bleConnected = false;
    _provisionResult = null;
    notifyListeners();
  }

  /// Sends "SSID\nPASSWORD" to the box and waits (up to 8s) for the
  /// notification "ok" or "err:...". Returns true on success.
  Future<bool> provision(String ssid, String password) async {
    if (!supported) return false;
    _provisionResult = null;
    notifyListeners();
    _notifyWaiter = Completer<String>();
    try {
      final ok = await _channel
              .invokeMethod<bool>('writeProvision', {'ssid': ssid, 'password': password})
              .timeout(const Duration(seconds: 10)) ??
          false;
      if (!ok) {
        _notifyWaiter = null;
        _lastError = 'Ecriture BLE refusee';
        return false;
      }
      final status = await _notifyWaiter!.future.timeout(const Duration(seconds: 8));
      if (status == 'ok') return true;
      _lastError = status;
      return false;
    } on PlatformException catch (e) {
      _notifyWaiter = null;
      _lastError = e.message;
      return false;
    } on TimeoutException {
      _notifyWaiter = null;
      _lastError = 'Le boitier ne repond pas (deconnecte ou endormi)';
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<String?> readProvisionStatus() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('readProvisionStatus');
    } on PlatformException catch (e) {
      _lastError = e.message;
      return null;
    }
  }

  /// Scans the WiFi networks visible from the phone (the box will be
  /// provisioned with the selected one). Deduplicated by SSID, strongest
  /// signal first.
  Future<void> scanWifi() async {
    if (!supported) {
      _lastError = 'Provisioning non supporte sur cette plateforme';
      notifyListeners();
      return;
    }
    _scanningWifi = true;
    _wifiNetworks.clear();
    _lastError = null;
    notifyListeners();
    try {
      final list = await _channel.invokeListMethod<dynamic>('scanWifi');
      _wifiNetworks
        ..clear()
        ..addAll(
          (list ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => WifiNetwork.fromJson(e.cast<String, dynamic>())),
        );
    } on PlatformException catch (e) {
      _lastError = e.message;
    } finally {
      _scanningWifi = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }
}

class BleDevice {
  final String name;
  final String address;
  final int rssi;

  const BleDevice({required this.name, required this.address, required this.rssi});

  factory BleDevice.fromJson(Map<String, dynamic> json) => BleDevice(
        name: json['name']?.toString() ?? '',
        address: json['address']?.toString() ?? '',
        rssi: (json['rssi'] as num?)?.toInt() ?? 0,
      );
}

class WifiNetwork {
  final String ssid;
  final String bssid;
  final int level;

  const WifiNetwork({required this.ssid, required this.bssid, required this.level});

  factory WifiNetwork.fromJson(Map<String, dynamic> json) => WifiNetwork(
        ssid: json['ssid']?.toString() ?? '',
        bssid: json['bssid']?.toString() ?? '',
        level: (json['level'] as num?)?.toInt() ?? 0,
      );
}
