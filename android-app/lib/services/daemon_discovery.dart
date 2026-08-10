import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Finds the Passerelle daemon on the LAN without typing its IP: sends a
/// "PASSERELLE_DISCOVER" broadcast, the daemon (UDP 8082) answers with its
/// ports. Works on Android and Linux (pure dart:io, no permissions).
class DaemonDiscovery {
  static const int _discoveryPort = 8082;
  static final List<int> _magic = 'PASSERELLE_DISCOVER'.codeUnits;

  /// Scans for daemons during [timeout]; returns the list of found ones.
  static Future<List<DaemonEndpoint>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final results = <DaemonEndpoint>[];
    late RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        try {
          final json = jsonDecode(utf8.decode(dg.data, allowMalformed: true));
          if (json is Map<String, dynamic> && json['type'] == 'discover') {
            results.add(DaemonEndpoint(
              host: dg.address.address,
              wsPort: (json['ws_port'] as num?)?.toInt() ?? 8080,
              httpPort: (json['http_port'] as num?)?.toInt() ?? 8081,
            ));
          }
        } catch (_) {
          // Not a discovery answer; ignore.
        }
      });
      socket.send(_magic, InternetAddress('255.255.255.255'), _discoveryPort);
      await Future<void>.delayed(timeout);
    } finally {
      socket.close();
    }
    return results;
  }
}

class DaemonEndpoint {
  final String host;
  final int wsPort;
  final int httpPort;

  const DaemonEndpoint({
    required this.host,
    required this.wsPort,
    required this.httpPort,
  });
}
