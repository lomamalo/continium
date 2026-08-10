import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/box_provisioning.dart';
import '../services/websocket_service.dart';
import 'box_setup_card.dart';
import 'box_status_card.dart';
import 'continuity_card.dart';

class StatusPanel extends StatelessWidget {
  const StatusPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    final wide = MediaQuery.sizeOf(context).width >= 880;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DaemonConnectionBanner(state: ws.state, error: ws.lastError),
              const SizedBox(height: 16),
              if (wide)
                const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: ContinuityCard()),
                    SizedBox(width: 16),
                    Expanded(child: BoxStatusCard()),
                  ],
                )
              else ...[
                const ContinuityCard(),
                const SizedBox(height: 16),
                const BoxStatusCard(),
              ],
              const SizedBox(height: 16),
              if (BoxProvisioningService.supported) ...[
                const BoxSetupCard(),
                const SizedBox(height: 16),
              ],
              if (ws.mac != null || ws.chip != null)
                _DeviceIdentityCard(ws: ws),
            ],
          ),
        ),
      ),
    );
  }
}

class _DaemonConnectionBanner extends StatelessWidget {
  final DaemonLinkState state;
  final String? error;
  const _DaemonConnectionBanner({required this.state, required this.error});

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (state) {
      DaemonLinkState.connected => (
        Icons.cloud_done_outlined,
        AppColors.statusGreen,
        'Daemon connecte',
      ),
      DaemonLinkState.connecting => (
        Icons.cloud_sync_outlined,
        AppColors.statusOrange,
        'Connexion au daemon...',
      ),
      DaemonLinkState.disconnected => (
        Icons.cloud_off_outlined,
        AppColors.statusRed,
        'Daemon deconnecte',
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (state == DaemonLinkState.disconnected && error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceIdentityCard extends StatelessWidget {
  final WebSocketService ws;
  const _DeviceIdentityCard({required this.ws});

  @override
  Widget build(BuildContext context) {
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
              Icon(Icons.developer_board, color: AppColors.accent, size: 18),
              SizedBox(width: 8),
              Text(
                'Boitier',
                style: TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Divider(color: AppColors.divider),
          _row('Puce', ws.chip ?? '—'),
          _row('Adresse MAC', ws.mac ?? '—'),
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
}
