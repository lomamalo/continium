import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../services/daemon_discovery.dart';
import '../services/websocket_service.dart';
import '../widgets/status_panel.dart';
import '../widgets/continuity_page.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Reconnect silently to the last known daemon, or discover it on the LAN
  /// (UDP). The connect dialog is only shown when neither works, so a fresh
  /// install needs no manual tap either.
  Future<void> _init() async {
    debugPrint('[continium] _init: demarrage');
    final prefs = await SharedPreferences.getInstance();
    var host = prefs.getString('daemon_host');
    var port = prefs.getInt('daemon_port') ?? 8080;
    debugPrint('[continium] _init: config memorisee = $host:$port');
    if (host == null || host.isEmpty) {
      debugPrint('[continium] _init: pas de config, decouverte UDP...');
      final found = await DaemonDiscovery.discover();
      debugPrint('[continium] _init: decouverte -> ${found.length} daemon(s)');
      if (found.isNotEmpty) {
        host = found.first.host;
        port = found.first.wsPort;
      }
    }
    if (host != null && host.isNotEmpty) {
      await _rememberConfig(host, port);
      debugPrint('[continium] _init: connexion a $host:$port');
      await context.read<WebSocketService>().connect(host, port);
      debugPrint('[continium] _init: connect() termine');
      return;
    }
    debugPrint('[continium] _init: dialogue de connexion');
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _showConnectDialog());
  }

  static Future<void> _rememberConfig(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('daemon_host', host);
    await prefs.setInt('daemon_port', port);
  }

  Future<void> _showConnectDialog() async {
    // NOTE: default IP is specific to the dev network; see "Problemes
    // connus" in ARCHITECTURE.md. The daemon is also found automatically
    // (UDP discovery) so the address rarely needs typing.
    final hostController = TextEditingController(text: '192.168.1.180');
    final portController = TextEditingController(text: '8080');
    final discovery = _DiscoveryBox(
      hostController: hostController,
      portController: portController,
    );

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => AlertDialog(
            backgroundColor: AppColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: const [
                Icon(Icons.dns_outlined, color: AppColors.accent),
                SizedBox(width: 10),
                Text('Connexion au daemon'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                discovery,
                const SizedBox(height: 12),
                TextField(
                  controller: hostController,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Adresse hote',
                    prefixIcon: const Icon(Icons.router_outlined, size: 20),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.divider),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Port',
                    prefixIcon: const Icon(Icons.tag, size: 20),
                    filled: true,
                    fillColor: AppColors.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppColors.divider),
                    ),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
            actions: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                ),
                onPressed: () {
                  final port = int.tryParse(portController.text) ?? 8080;
                  _rememberConfig(hostController.text, port);
                  context.read<WebSocketService>().connect(
                    hostController.text,
                    port,
                  );
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.link),
                label: const Text('Connecter'),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    final connected = ws.state == DaemonLinkState.connected;

    final pages = const [StatusPanel(), ContinuityPage()];
    const titles = ['Connexion', 'Continuity'];
    final wide = MediaQuery.sizeOf(context).width >= 880;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/continium.png',
                height: 26,
                width: 26,
                errorBuilder:
                    (_, __, ___) => const Icon(Icons.hub_outlined, size: 22),
              ),
            ),
            const SizedBox(width: 10),
            Text(titles[_selectedIndex]),
          ],
        ),
        actions: [
          _DaemonStatusChip(connected: connected),
          PopupMenuButton<int>(
            tooltip: 'Menu',
            initialValue: _selectedIndex,
            icon: const Icon(Icons.menu),
            color: AppColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: AppColors.divider),
            ),
            onSelected: (i) => setState(() => _selectedIndex = i),
            itemBuilder:
                (context) => [
                  for (var i = 0; i < titles.length; i++)
                    PopupMenuItem<int>(
                      value: i,
                      child: Row(
                        children: [
                          Icon(
                            i == 0 ? Icons.bluetooth_connected : Icons.devices,
                            size: 20,
                            color:
                                i == _selectedIndex
                                    ? AppColors.accent
                                    : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            titles[i],
                            style: TextStyle(
                              color:
                                  i == _selectedIndex
                                      ? AppColors.accent
                                      : AppColors.textPrimary,
                              fontWeight:
                                  i == _selectedIndex
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                            ),
                          ),
                          if (i == _selectedIndex) ...[
                            const Spacer(),
                            const Icon(
                              Icons.check,
                              size: 16,
                              color: AppColors.accent,
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
          ),
          IconButton(
            tooltip: 'Parametres de connexion',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showConnectDialog,
          ),
        ],
      ),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (i) => setState(() => _selectedIndex = i),
              backgroundColor: AppColors.background,
              indicatorColor: AppColors.accent,
              labelType: NavigationRailLabelType.all,
              selectedIconTheme: const IconThemeData(color: Colors.black),
              unselectedIconTheme: const IconThemeData(
                color: AppColors.textSecondary,
              ),
              selectedLabelTextStyle: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelTextStyle: const TextStyle(
                color: AppColors.textSecondary,
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.bluetooth_connected_outlined),
                  selectedIcon: Icon(Icons.bluetooth_connected),
                  label: Text('Connexion'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.devices_outlined),
                  selectedIcon: Icon(Icons.devices),
                  label: Text('Continuity'),
                ),
              ],
            ),
          Expanded(child: IndexedStack(index: _selectedIndex, children: pages)),
        ],
      ),
      bottomNavigationBar:
          wide
              ? null
              : NavigationBar(
                backgroundColor: AppColors.card,
                indicatorColor: AppColors.accent,
                selectedIndex: _selectedIndex,
                onDestinationSelected:
                    (i) => setState(() => _selectedIndex = i),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.bluetooth_connected_outlined),
                    selectedIcon: Icon(Icons.bluetooth_connected),
                    label: 'Connexion',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.devices_outlined),
                    selectedIcon: Icon(Icons.devices),
                    label: 'Continuity',
                  ),
                ],
              ),
      floatingActionButton:
          _selectedIndex == 1
              ? FloatingActionButton.extended(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                onPressed: () => _showAddItemDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter'),
              )
              : null,
    );
  }

  Future<void> _showAddItemDialog(BuildContext context) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder:
          (context) => AlertDialog(
            backgroundColor: AppColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: const [
                Icon(Icons.post_add, color: AppColors.accent),
                SizedBox(width: 10),
                Text('Ajouter a Continuity'),
              ],
            ),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Colle un lien, un texte...',
                hintStyle: const TextStyle(color: AppColors.textSecondary),
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
                onPressed: () {
                  final content = controller.text.trim();
                  if (content.isNotEmpty) {
                    context.read<WebSocketService>().addContinuityItem(content);
                  }
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.send),
                label: const Text('Envoyer'),
              ),
            ],
          ),
    );
  }
}

class _DiscoveryBox extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  const _DiscoveryBox({
    required this.hostController,
    required this.portController,
  });

  @override
  State<_DiscoveryBox> createState() => _DiscoveryBoxState();
}

class _DiscoveryBoxState extends State<_DiscoveryBox> {
  String? _found;
  bool _searching = false;
  bool _autoFilled = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  Future<void> _search() async {
    setState(() => _searching = true);
    final found = await DaemonDiscovery.discover(
      timeout: const Duration(seconds: 2),
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (found.isNotEmpty) {
        final d = found.first;
        if (!_autoFilled) {
          _autoFilled = true;
          widget.hostController.text = d.host;
          widget.portController.text = '${d.wsPort}';
        }
        _found = 'Passerelle trouvee automatiquement (${d.host})';
      } else {
        _found = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_searching)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text(
                  'Recherche du daemon sur le reseau...',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          )
        else if (_found != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: AppColors.statusGreen,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _found!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.statusGreen,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Relancer la recherche',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.refresh,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: _search,
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.info_outline,
                  color: AppColors.textSecondary,
                  size: 15,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Daemon introuvable : verifie qu il tourne sur le PC.',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DaemonStatusChip extends StatelessWidget {
  final bool connected;
  const _DaemonStatusChip({required this.connected});

  @override
  Widget build(BuildContext context) {
    final color = connected ? AppColors.statusGreen : AppColors.statusRed;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            connected ? Icons.podcasts : Icons.wifi_off,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            connected ? 'Daemon' : 'Hors ligne',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
