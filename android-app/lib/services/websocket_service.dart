import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum DaemonLinkState { disconnected, connecting, connected }

class WsEvent {
  final DateTime timestamp;
  final Map<String, dynamic> data;
  final String raw;

  WsEvent({required this.timestamp, required this.data, required this.raw});
}

const int _kMaxBufferedMessages = 200;
const Duration _kReconnectDelay = Duration(seconds: 3);
const Duration _kInfoRefreshInterval = Duration(seconds: 30);
// Re-requests the continuity store on a timer so a missed push (e.g. the
// phone's socket dropping briefly, see "[ws] client disconnected" in the
// daemon log) is picked up within seconds instead of staying stale.
const Duration _kContinuityRefreshInterval = Duration(seconds: 15);
const Duration _kBoxStatusRefreshInterval = Duration(seconds: 30);

/// A continuity item: something started on the PC (YouTube link, copied
/// text, file...) that can be finished on the phone.
class ContinuityItem {
  final String id;
  /// Top-level compartment: "video" | "presse-papier" | "fichier"
  final String category;
  /// Sub-type: "youtube" | "lien" | "texte" | "markdown" | "code" | ...
  final String kind;
  /// Human-readable title built by the daemon.
  final String title;
  final String content;
  final String source; // "clipboard" | "manual" | "app" | "extension" | "hotkey"
  final DateTime createdAt;
  final Map<String, dynamic> meta;

  const ContinuityItem({
    required this.id,
    required this.category,
    required this.kind,
    required this.title,
    required this.content,
    required this.source,
    required this.createdAt,
    this.meta = const {},
  });

  bool get isVideo => category == 'video';
  bool get isFile => category == 'fichier';
  bool get isYoutube => kind == 'youtube' && videoId != null;
  bool get isLink => !isYoutube && kind == 'lien';

  String? get videoId => meta['video_id']?.toString();
  int get positionS => (meta['position_s'] as num?)?.toInt() ?? 0;
  int get durationS => (meta['duration_s'] as num?)?.toInt() ?? 0;
  String? get filePath => meta['path']?.toString();
  bool get syncedBack => meta['synced_back'] == true;

  /// The YouTube URL at the saved position, or null.
  String? get youtubeUrl {
    final vid = videoId;
    if (vid == null) return null;
    final t = positionS > 0 ? '&t=$positionS' : '';
    return 'https://www.youtube.com/watch?v=$vid$t';
  }

  /// URL that opens this item (video URL, link, ...), or null.
  String? get openUrl {
    if (isYoutube) return youtubeUrl;
    final uri = Uri.tryParse(content);
    if (uri != null && uri.hasScheme) return content;
    return null;
  }

  factory ContinuityItem.fromJson(Map<String, dynamic> json) {
    final category = json['category']?.toString() ?? 'presse-papier';
    final kind = json['kind']?.toString() ?? '';
    return ContinuityItem(
      id: json['id']?.toString() ?? '',
      category: category,
      kind: kind,
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      source: json['source']?.toString() ?? 'manual',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['created_at_ms'] as num?)?.toInt() ?? 0,
      ),
      meta: (json['meta'] as Map<String, dynamic>?) ?? const {},
    );
  }
}

/// Last status reported by the box (POST /box/status): battery, how many
/// continuity items are buffered in its SPIFFS copy, and its last sync.
class BoxStatus {
  final int batteryMv;
  final int stored;
  final int lastSyncMs;
  final String firmware;

  const BoxStatus({
    required this.batteryMv,
    required this.stored,
    required this.lastSyncMs,
    this.firmware = '',
  });

  factory BoxStatus.fromJson(Map<String, dynamic> json) => BoxStatus(
        batteryMv: (json['battery_mv'] as num?)?.toInt() ?? 0,
        stored: (json['stored'] as num?)?.toInt() ?? 0,
        lastSyncMs: (json['last_sync_ms'] as num?)?.toInt() ?? 0,
        firmware: json['firmware']?.toString() ?? '',
      );

  DateTime? get lastSyncAt =>
      lastSyncMs > 0 ? DateTime.fromMillisecondsSinceEpoch(lastSyncMs) : null;
}

/// WebSocket client + state management (Provider pattern) for the
/// connection to passerelle-daemon. The daemon relays the ESP32's JSON
/// telemetry (`alive`/`info`, see docs/proto/esp32-uart-protocol.md)
/// verbatim, so the getters below reflect the *real*, live state of the
/// board: BLE link, charging, battery voltage.
class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _infoRefreshTimer;
  Timer? _continuityRefreshTimer;
  Timer? _boxStatusRefreshTimer;

  String? _host;
  int? _port;
  String? _lastError;
  String? get lastError => _lastError;

  DaemonLinkState _state = DaemonLinkState.disconnected;
  DaemonLinkState get state => _state;

  final List<WsEvent> _messages = [];
  List<WsEvent> get messages => List.unmodifiable(_messages);

  final List<ContinuityItem> _continuityItems = [];
  /// Continuity items, most recent first.
  List<ContinuityItem> get continuityItems => List.unmodifiable(_continuityItems);
  int get continuityCount => _continuityItems.length;

  BoxStatus? _boxStatus;
  /// Last status reported by the box, or null until the daemon has one.
  BoxStatus? get boxStatus => _boxStatus;
  DateTime? get boxStatusAt => _boxStatusAt;
  DateTime? _boxStatusAt;

  Map<String, dynamic>? _lastFileBacked;
  /// Last `file_backed` event (id, path, wrote) or null. The UI reads and
  /// clears it to show a one-shot confirmation.
  Map<String, dynamic>? get lastFileBacked => _lastFileBacked;
  void clearLastFileBacked() {
    _lastFileBacked = null;
  }

  void _setState(DaemonLinkState newState) {
    _state = newState;
    notifyListeners();
  }

  Future<void> connect(String host, int port) async {
    _host = host;
    _port = port;
    _reconnectTimer?.cancel();
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_host == null || _port == null) return;

    _setState(DaemonLinkState.connecting);
    try {
      final uri = Uri.parse('ws://$_host:$_port');
      // Client-side ping keeps the link alive through NAT/AP power-saving
      // and makes dead sockets fail fast, so the reconnect+rebase below is
      // quick instead of "seen 1 minute later".
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 15),
      );

      // Wait for the actual handshake to complete (or fail) before
      // reporting "connected" -- no optimistic state.
      await channel.ready;

      _channel = channel;
      _lastError = null;
      _setState(DaemonLinkState.connected);

      // The box only reports firmware/uptime/MAC on demand (`info`); ask for
      // it on connect and periodically so the continuity card's tiles stay
      // populated even if the user never taps the "Info" button.
      sendCommand('info');
      _infoRefreshTimer?.cancel();
      _infoRefreshTimer = Timer.periodic(_kInfoRefreshInterval, (_) => sendCommand('info'));

      // Fetch the continuity store (items started on the PC) as soon as the
      // link is up; updates are pushed by the daemon afterwards, and the
      // timer below re-syncs the store in case a push got missed.
      requestContinuityList();
      _continuityRefreshTimer?.cancel();
      _continuityRefreshTimer = Timer.periodic(
        _kContinuityRefreshInterval,
        (_) => requestContinuityList(),
      );

      requestBoxStatus();
      _boxStatusRefreshTimer?.cancel();
      _boxStatusRefreshTimer = Timer.periodic(
        _kBoxStatusRefreshInterval,
        (_) => requestBoxStatus(),
      );

      _subscription = channel.stream.listen(
        _onMessage,
        onDone: _onDisconnected,
        onError: (Object e) {
          _lastError = e.toString();
          _onDisconnected();
        },
        cancelOnError: true,
      );
    } catch (e) {
      _lastError = e.toString();
      _onDisconnected();
    }
  }

  void _onMessage(dynamic raw) {
    final text = raw.toString();
    Map<String, dynamic> data;
    try {
      data = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      data = {'type': 'raw', 'value': text};
    }

    _messages.add(WsEvent(timestamp: DateTime.now(), data: data, raw: text));
    if (_messages.length > _kMaxBufferedMessages) {
      _messages.removeAt(0);
    }

    _handleContinuity(data);
    notifyListeners();
  }

  void _handleContinuity(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'continuity_list':
        final items = (data['items'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ContinuityItem.fromJson)
            .toList();
        _continuityItems
          ..clear()
          ..addAll(items);
        _continuityItems.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case 'continuity_item':
        final item = ContinuityItem.fromJson(data['item'] as Map<String, dynamic>? ?? {});
        if (item.id.isNotEmpty) {
          _continuityItems
            ..removeWhere((e) => e.id == item.id)
            ..add(item)
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        }
      case 'continuity_removed':
        final id = data['id']?.toString();
        if (id != null) _continuityItems.removeWhere((e) => e.id == id);
      case 'file_backed':
        // The daemon wrote the edited content back to the PC file. Refresh
        // the store so the item shows its updated `synced_back` meta.
        _lastFileBacked = data;
        requestContinuityList();
      case 'box_status':
        final status = data['status'] as Map<String, dynamic>?;
        if (status != null) {
          _boxStatus = BoxStatus.fromJson(status);
          _boxStatusAt = DateTime.now();
        }
    }
  }

  void _onDisconnected() {
    _setState(DaemonLinkState.disconnected);
    _subscription?.cancel();
    _channel = null;
    _infoRefreshTimer?.cancel();
    _infoRefreshTimer = null;
    _continuityRefreshTimer?.cancel();
    _continuityRefreshTimer = null;
    _boxStatusRefreshTimer?.cancel();
    _boxStatusRefreshTimer = null;

    // Auto-reconnect every 3s.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_kReconnectDelay, _doConnect);
  }

  void send(String msg) {
    _channel?.sink.add(msg);
  }

  void sendCommand(String command, [String? arg]) {
    final line = arg != null ? '$command $arg\n' : '$command\n';
    send(line);
  }

  /// Ask the daemon for the full continuity store. The daemon answers with
  /// `continuity_list` (handled in [_handleContinuity]).
  void requestContinuityList() => send('{"type":"continuity_list"}\n');

  /// Add a continuity item from the app itself (e.g. a link found on the
  /// phone). The daemon stores it, categorizes it and broadcasts it.
  void addContinuityItem(String content, {Map<String, dynamic>? hints}) {
    final payload = <String, dynamic>{
      'type': 'continuity_add',
      'content': content,
      'source': 'app',
      if (hints != null) ...hints,
    };
    send(jsonEncode(payload) + '\n');
  }

  /// Delete a continuity item. The daemon broadcasts `continuity_removed`.
  void deleteContinuityItem(String id) =>
      send('{"type":"continuity_del","id":${jsonEncode(id)}}\n');

  /// Phone -> PC: send edited content back to the file this item came from.
  /// The daemon writes it to `meta.path` on the PC (when it exists) and
  /// broadcasts `file_backed`.
  void sendBack(String id, String content) => send(
        '{"type":"continuity_back","id":${jsonEncode(id)},"content":${jsonEncode(content)}}\n',
      );

  /// Ask the daemon for the box's last status. It answers locally with
  /// `box_status` (no need for the box to be plugged in).
  void requestBoxStatus() => send('{"type":"box_status"}\n');

  void clearLog() {
    _messages.clear();
    notifyListeners();
  }

  /// Most recent message of a given `type` (e.g. "info", "alive", "boot"),
  /// or null if none has been received yet.
  Map<String, dynamic>? latestOfType(String type) {
    for (final e in _messages.reversed) {
      if (e.data['type'] == type) return e.data;
    }
    return null;
  }

  /// Live ESP32 telemetry, merging `info` (richer, less frequent), `alive`
  /// (every second) and the last `box_status` HTTP sync report, so the most
  /// recent value of each field wins. The box only emits on the serial link
  /// while awake; `box_status` keeps the picture populated between syncs.
  Map<String, dynamic> get deviceTelemetry {
    final info = latestOfType('info') ?? {};
    final alive = latestOfType('alive') ?? {};
    final boot = latestOfType('boot') ?? {};
    final box = {
      if (_boxStatus != null && _boxStatus!.batteryMv > 0)
        'battery_mv': _boxStatus!.batteryMv,
    };
    return {...boot, ...info, ...alive, ...box};
  }

  bool get hasDeviceTelemetry => deviceTelemetry.isNotEmpty;
  bool get bleConnected => deviceTelemetry['ble_connected'] == true;
  bool get charging => deviceTelemetry['charging'] == true;
  int? get batteryMv => (deviceTelemetry['battery_mv'] as num?)?.toInt();
  int? get deviceStateValue => (deviceTelemetry['state'] as num?)?.toInt();
  String? get firmwareVersion => deviceTelemetry['firmware']?.toString();
  int? get uptimeMs => (deviceTelemetry['uptime_ms'] as num?)?.toInt();
  String? get chip => deviceTelemetry['chip']?.toString();
  String? get mac => deviceTelemetry['mac']?.toString();

  /// Timestamp of the most recent telemetry message (`alive`/`info`), or
  /// null if none has been received yet. The continuity card uses this to
  /// distinguish "boitier present et en vie" from "boitier muet".
  DateTime? get lastTelemetryAt {
    for (final e in _messages.reversed) {
      final type = e.data['type'];
      if (type == 'alive' || type == 'info') return e.timestamp;
    }
    return null;
  }

  /// True while the box has reported telemetry recently (within 15s).
  /// The box emits `alive` every second, so anything older means the
  /// serial/daemon link is down even though the WebSocket itself may be up.
  bool get isTelemetryFresh {
    final at = lastTelemetryAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < const Duration(seconds: 15);
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _infoRefreshTimer?.cancel();
    _continuityRefreshTimer?.cancel();
    _boxStatusRefreshTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
