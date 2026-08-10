import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/websocket_service.dart';

/// The live status of the ESP32, as inferred from its own telemetry
/// (see docs/proto/esp32-uart-protocol.md). Mirrors the priority order of
/// the firmware's own LED game (esp32-firmware/main/ledgame.c) so the app
/// and the physical board are always telling the same story.
enum _DeviceMode {
  awaitingTelemetry,
  booting,
  error,
  pairing,
  lowBattery,
  chargingConnected,
  chargingOnly,
  connected,
  asleep,
}
const int _kBatteryLowMv = 3450;
const int _kBatteryFullMv = 4150;
const int _kBatteryEmptyMv = 3300;

class _Palette {
  static const connected = Color(0xFF4CAF50);
  static const charging = Color(0xFFFFAB40);
  static const chargingConnected = Color(0xFF00C8C8);
  static const low = Color(0xFFFF5252);
  static const pairing = Color(0xFFE040FB);
  static const booting = Color(0xFFFFD600);
  static const neutral = Color(0xFF4A4A4A);
}

class ContinuityCard extends StatefulWidget {
  const ContinuityCard({super.key});

  @override
  State<ContinuityCard> createState() => _ContinuityCardState();
}

class _ContinuityCardState extends State<ContinuityCard>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _elapsed = elapsed);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  // ---- envelopes mirroring esp32-firmware/main/ledgame.c ----

  double _breathe(int periodMs) {
    final phase = (_elapsed.inMilliseconds % periodMs) / periodMs;
    return 0.15 + 0.85 * (0.5 - 0.5 * math.cos(2 * math.pi * phase));
  }

  double _heartbeat(int periodMs) {
    final t = (_elapsed.inMilliseconds % periodMs).toDouble();
    final pulseWidth = periodMs * 0.10;
    final p1 = t;
    final p2 = t - periodMs * 0.20;
    double v = 0;
    if (p1 >= 0 && p1 < pulseWidth) {
      v = math.sin(math.pi * (p1 / pulseWidth));
    } else if (p2 >= 0 && p2 < pulseWidth) {
      v = 0.7 * math.sin(math.pi * (p2 / pulseWidth));
    }
    return 0.05 + 0.95 * v;
  }

  double _singlePulse(int periodMs) {
    final t = (_elapsed.inMilliseconds % periodMs).toDouble();
    final pulseWidth = periodMs * 0.15;
    if (t < pulseWidth) return math.sin(math.pi * (t / pulseWidth));
    return 0.0;
  }

  double _fastBlink(int periodMs) {
    return (_elapsed.inMilliseconds % periodMs) < periodMs / 2 ? 1.0 : 0.15;
  }

  _DeviceMode _modeFor(WebSocketService ws) {
    // The app talks to the box through the daemon (WebSocket), not through
    // BLE. The card's main state therefore follows the daemon link and the
    // freshness of the box's own telemetry; BLE remains a secondary detail.
    if (ws.state != DaemonLinkState.connected) {
      return _DeviceMode.awaitingTelemetry;
    }
    if (!ws.isTelemetryFresh) {
      // On battery the box sleeps between two sync cycles (~10 min):
      // telemetry older than 15s just means it is asleep, not broken.
      return ws.hasDeviceTelemetry ? _DeviceMode.asleep : _DeviceMode.awaitingTelemetry;
    }

    final state = ws.deviceStateValue;
    if (state == 0) return _DeviceMode.booting;
    if (state == 4) return _DeviceMode.error;
    if (state == 2) return _DeviceMode.pairing;

    final mv = ws.batteryMv;
    final charging = ws.charging;
    final connected = ws.bleConnected;

    if (charging) {
      return connected ? _DeviceMode.chargingConnected : _DeviceMode.chargingOnly;
    }
    if (mv != null && mv < _kBatteryLowMv) return _DeviceMode.lowBattery;
    return _DeviceMode.connected;
  }

  ({Color color, double brightness, bool solid}) _renderFor(_DeviceMode mode, bool full) {
    switch (mode) {
      case _DeviceMode.awaitingTelemetry:
        return (color: _Palette.neutral, brightness: 0.5, solid: true);
      case _DeviceMode.booting:
        return (color: _Palette.booting, brightness: _fastBlink(500), solid: false);
      case _DeviceMode.error:
        return (color: Colors.red, brightness: _fastBlink(250), solid: false);
      case _DeviceMode.pairing:
        return (color: _Palette.pairing, brightness: _breathe(500), solid: false);
      case _DeviceMode.lowBattery:
        return (color: _Palette.low, brightness: _singlePulse(3000), solid: false);
      case _DeviceMode.chargingConnected:
        return full
            ? (color: _Palette.chargingConnected, brightness: 1.0, solid: true)
            : (color: _Palette.chargingConnected, brightness: _breathe(2200), solid: false);
      case _DeviceMode.chargingOnly:
        return full
            ? (color: _Palette.charging, brightness: 1.0, solid: true)
            : (color: _Palette.charging, brightness: _breathe(2200), solid: false);
      case _DeviceMode.connected:
        return (color: _Palette.connected, brightness: _heartbeat(1800), solid: false);
      case _DeviceMode.asleep:
        return (color: _Palette.neutral, brightness: _singlePulse(5000), solid: false);
    }
  }

  String _modeLabel(_DeviceMode mode) {
    switch (mode) {
      case _DeviceMode.awaitingTelemetry:
        return 'En attente du boitier';
      case _DeviceMode.booting:
        return 'Demarrage du boitier';
      case _DeviceMode.error:
        return 'Erreur boitier';
      case _DeviceMode.pairing:
        return 'Appairage en cours';
      case _DeviceMode.lowBattery:
        return 'Batterie faible';
      case _DeviceMode.chargingConnected:
        return 'Connecte et en charge';
      case _DeviceMode.chargingOnly:
        return 'En charge';
      case _DeviceMode.connected:
        return 'Connecte au boitier';
      case _DeviceMode.asleep:
        return 'Boitier en veille';
    }
  }

  IconData _bluetoothIcon(bool connected, _DeviceMode mode) {
    if (mode == _DeviceMode.pairing) return Icons.bluetooth_searching;
    return connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled;
  }

  IconData _batteryIcon(int? mv, bool charging) {
    if (mv == null) return Icons.battery_unknown;
    if (charging) return Icons.battery_charging_full;
    if (mv < _kBatteryLowMv) return Icons.battery_alert;
    final pct = _batteryPercent(mv);
    if (pct >= 95) return Icons.battery_full;
    if (pct >= 60) return Icons.battery_5_bar;
    if (pct >= 35) return Icons.battery_3_bar;
    return Icons.battery_2_bar;
  }

  int _batteryPercent(int mv) {
    final pct = (mv - _kBatteryEmptyMv) / (_kBatteryFullMv - _kBatteryEmptyMv) * 100;
    return pct.clamp(0, 100).round();
  }

  String _formatUptime(int? ms) {
    if (ms == null) return '—';
    final total = Duration(milliseconds: ms);
    final h = total.inHours;
    final m = total.inMinutes % 60;
    final s = total.inSeconds % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
    return '${s}s';
  }

  String _ago(DateTime? at) {
    if (at == null) return 'inconnue';
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'il y a ${d.inSeconds}s';
    if (d.inMinutes < 60) return 'il y a ${d.inMinutes} min';
    if (d.inHours < 24) return 'il y a ${d.inHours} h';
    return 'il y a ${d.inDays} j';
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    final mode = _modeFor(ws);
    final full = (ws.batteryMv ?? 0) >= _kBatteryFullMv;
    final render = _renderFor(mode, full);
    final mv = ws.batteryMv;
    final daemonUp = ws.state == DaemonLinkState.connected;
    final label = !daemonUp
        ? 'En attente du daemon'
        : (!ws.isTelemetryFresh
            ? (ws.hasDeviceTelemetry ? 'Boitier en veille' : 'Boitier injoignable')
            : _modeLabel(mode));
    final lastSync = ws.lastTelemetryAt;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
        boxShadow: [
          BoxShadow(
            color: render.color.withValues(alpha: 0.10),
            blurRadius: 30,
            spreadRadius: -6,
          ),
        ],
      ),
      child: Column(
        children: [
          SizedBox(
            height: 150,
            width: 150,
            child: CustomPaint(
              painter: _ContinuumGlyphPainter(
                color: render.color,
                brightness: render.brightness,
                solid: render.solid,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          if (mode == _DeviceMode.asleep)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'En veille entre deux cycles (~10 min) — derniere synchro '
                '${_ago(lastSync)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 11.5),
              ),
            ),
          const SizedBox(height: 20),
          const Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _TelemetryTile(
                icon: _bluetoothIcon(ws.bleConnected, mode),
                iconColor: ws.bleConnected ? AppColors.statusGreen : AppColors.textSecondary,
                label: ws.bleConnected ? 'Bluetooth' : 'Hors ligne',
                value: ws.bleConnected ? 'Lie' : 'Non lie',
              ),
              _TelemetryTile(
                icon: _batteryIcon(mv, ws.charging),
                iconColor: ws.charging
                    ? AppColors.statusOrange
                    : (mv != null && mv < _kBatteryLowMv ? AppColors.statusRed : AppColors.textPrimary),
                label: 'Batterie',
                value: mv != null ? '${_batteryPercent(mv)}%' : '—',
              ),
              _TelemetryTile(
                icon: Icons.memory,
                iconColor: AppColors.textPrimary,
                label: 'Firmware',
                value: ws.firmwareVersion ?? '—',
              ),
              _TelemetryTile(
                icon: Icons.schedule,
                iconColor: AppColors.textPrimary,
                label: 'Uptime',
                value: _formatUptime(ws.uptimeMs),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TelemetryTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  const _TelemetryTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 22),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
        ),
      ],
    );
  }
}

/// Paints the continium glyph (ring with two gaps, two dots plugging them,
/// horizontal bar through the middle) -- the same motif as the app icon --
/// scaled in color/brightness to reflect the live device state.
class _ContinuumGlyphPainter extends CustomPainter {
  final Color color;
  final double brightness;
  final bool solid;

  _ContinuumGlyphPainter({required this.color, required this.brightness, required this.solid});

  Color _scaled() {
    final b = brightness.clamp(0.0, 1.0);
    return Color.fromARGB(
      255,
      (color.r * 255 * b).round().clamp(0, 255),
      (color.g * 255 * b).round().clamp(0, 255),
      (color.b * 255 * b).round().clamp(0, 255),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 * 0.72;
    final strokeWidth = radius * 0.16;
    final dotRadius = radius * 0.17;
    final drawColor = _scaled();

    final glowPaint = Paint()
      ..color = drawColor.withValues(alpha: 0.35)
      ..maskFilter = MaskFilter.blur(ui.BlurStyle.normal, radius * 0.35);
    canvas.drawCircle(center, radius * 0.9, glowPaint);

    final ringPaint = Paint()
      ..color = drawColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    const gap = 0.44; // radians, gap half-angle around East/West
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Top arc: West+gap -> North -> East-gap (clockwise).
    canvas.drawArc(rect, math.pi + gap, math.pi - 2 * gap, false, ringPaint);
    // Bottom arc: East+gap -> South -> West-gap (clockwise).
    canvas.drawArc(rect, gap, math.pi - 2 * gap, false, ringPaint);

    final dotPaint = Paint()..color = drawColor;
    final eastDot = center + Offset(radius, 0);
    final westDot = center + Offset(-radius, 0);
    canvas.drawCircle(eastDot, dotRadius, dotPaint);
    canvas.drawCircle(westDot, dotRadius, dotPaint);

    final barPaint = Paint()
      ..color = drawColor
      ..strokeWidth = strokeWidth * 0.85
      ..strokeCap = StrokeCap.round;
    final barHalfLength = radius - dotRadius * 1.6;
    canvas.drawLine(
      center - Offset(barHalfLength, 0),
      center + Offset(barHalfLength, 0),
      barPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ContinuumGlyphPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.brightness != brightness ||
        oldDelegate.solid != solid;
  }
}
