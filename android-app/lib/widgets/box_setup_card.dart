import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/box_provisioning.dart';

/// Setup of the box's WiFi, over BLE: scan for the box, connect, pick a
/// WiFi network, type its password, send. Once provisioned, the box
/// connects to that network and syncs on battery (see docs/ARCHITECTURE.md).
class BoxSetupCard extends StatefulWidget {
  const BoxSetupCard({super.key});

  @override
  State<BoxSetupCard> createState() => _BoxSetupCardState();
}

class _BoxSetupCardState extends State<BoxSetupCard> {
  String? _selectedDevice;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final prov = context.read<BoxProvisioningService>();
      prov.init();
      prov.ensurePermissions(what: 'ble');
    });
  }

  Future<void> _scanBle() async {
    final prov = context.read<BoxProvisioningService>();
    final ok = await prov.ensurePermissions(what: 'ble');
    if (!mounted) return;
    if (!ok) {
      _snack('Permissions Bluetooth refusees');
      return;
    }
    await prov.scanBle();
  }

  Future<void> _scanWifi() async {
    final prov = context.read<BoxProvisioningService>();
    final ok = await prov.ensurePermissions(what: 'wifi');
    if (!mounted) return;
    if (!ok) {
      _snack('Permissions (localisation/WiFi) refusees');
      return;
    }
    await prov.scanWifi();
    if (!mounted) return;
    if (prov.lastError != null) _snack('Scan WiFi : ${prov.lastError}');
  }

  Future<void> _provision(String ssid) async {
    final controller = TextEditingController();
    final pass = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.vpn_key_outlined, color: AppColors.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                ssid,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Mot de passe WiFi',
            filled: true,
            fillColor: AppColors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.divider),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            icon: const Icon(Icons.send),
            label: const Text('Envoyer au boitier'),
          ),
        ],
      ),
    );
    if (pass == null || pass.isEmpty) return;

    setState(() => _sending = true);
    final prov = context.read<BoxProvisioningService>();
    final ok = await prov.provision(ssid, pass);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      _snack('Boitier configure ! Il va se connecter au WiFi "$ssid".');
    } else {
      _snack('Echec : ${prov.lastError ?? 'inconnu'}');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: AppColors.card),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<BoxProvisioningService>();

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
            children: [
              Icon(
                prov.bleConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                color: prov.bleConnected ? AppColors.statusGreen : AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text(
                'Configurer le boitier',
                style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_sending)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const Divider(color: AppColors.divider),
          const Text(
            '1. Connecte-toi au boitier (BLE)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: prov.scanningBle ? null : _scanBle,
                icon: prov.scanningBle
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar, size: 18),
                label: Text(prov.scanningBle ? 'Scan...' : 'Scanner'),
              ),
              if (prov.bleConnected) ...[
                Chip(
                  label: Text(_selectedDevice ?? 'Boitier'),
                  backgroundColor: AppColors.statusGreen.withValues(alpha: 0.12),
                  side: const BorderSide(color: AppColors.statusGreen),
                  labelStyle: const TextStyle(color: AppColors.statusGreen, fontSize: 12),
                ),
                IconButton(
                  tooltip: 'Deconnecter',
                  icon: const Icon(Icons.link_off, size: 18),
                  onPressed: prov.disconnectBle,
                ),
              ],
            ],
          ),
          if (prov.bleDevices.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final d in prov.bleDevices)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.developer_board, size: 20),
                title: Text(
                  d.name.isNotEmpty ? d.name : 'Boitier inconnu',
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(d.address, style: const TextStyle(fontSize: 11)),
                trailing: Text(
                  '${d.rssi} dBm',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
                onTap: () async {
                  setState(() => _selectedDevice = d.address);
                  await prov.connectBle(d.address);
                },
              ),
          ],
          const SizedBox(height: 12),
          const Text(
            '2. Envoie le WiFi de la maison',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: (prov.scanningWifi || !prov.bleConnected) ? null : _scanWifi,
            icon: const Icon(Icons.wifi, size: 18),
            label: Text(prov.scanningWifi ? 'Scan WiFi...' : 'Scanner les reseaux WiFi'),
          ),
          if (prov.wifiNetworks.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final n in prov.wifiNetworks)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.wifi, size: 20),
                title: Text(n.ssid, style: const TextStyle(fontSize: 14)),
                subtitle: Text('${n.level} dBm', style: const TextStyle(fontSize: 11)),
                onTap: () => _provision(n.ssid),
              ),
          ],
          if (prov.provisionResult != null) ...[
            const SizedBox(height: 8),
            Text(
              prov.provisionResult == 'ok'
                  ? 'Provisionne : le boitier va se connecter au WiFi.'
                  : 'Reponse du boitier : ${prov.provisionResult}',
              style: TextStyle(
                fontSize: 12,
                color: prov.provisionResult == 'ok'
                    ? AppColors.statusGreen
                    : AppColors.statusRed,
              ),
            ),
          ],
          if (prov.lastError != null) ...[
            const SizedBox(height: 4),
            Text(
              prov.lastError!,
              style: const TextStyle(color: AppColors.statusRed, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}
