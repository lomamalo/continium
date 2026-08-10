import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/websocket_service.dart';

/// Status of the box as reported through the daemon (POST /box/status):
/// battery level, number of continuity items buffered in its SPIFFS copy,
/// and its last WiFi sync time.
class BoxStatusCard extends StatelessWidget {
  const BoxStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    final status = ws.boxStatus;
    final at = ws.boxStatusAt;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.battery_charging_full, color: AppColors.accent, size: 18),
              SizedBox(width: 8),
              Text('Boitier (tampon)',
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)),
            ],
          ),
          const Divider(color: AppColors.divider),
          if (status == null)
            const Text('Aucune synchro du boitier pour l\'instant (il est en veille).',
                style: TextStyle(fontSize: 13))
          else ...[
            _row('Batterie', '${(status.batteryMv / 1000).toStringAsFixed(2)} V'),
            _row('Elements tamponnes', '${status.stored}'),
            _row(
              'Derniere synchro',
              status.lastSyncAt == null
                  ? 'jamais'
                  : _ago(status.lastSyncAt!),
            ),
            if (at != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Statut recu il y a ${_ago(at)}',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: AppColors.textSecondary)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    if (d.inDays < 1) return '${d.inHours} h';
    return '${d.inDays} j';
  }
}
