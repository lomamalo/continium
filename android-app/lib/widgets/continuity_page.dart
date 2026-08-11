import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../main.dart';
import '../screens/file_editor_screen.dart';
import '../services/websocket_service.dart';

/// The main page: everything started on the PC (copied YouTube links,
/// pasted text, files...) lands here, categorized, to be continued on the
/// phone.
class ContinuityPage extends StatefulWidget {
  const ContinuityPage({super.key});

  @override
  State<ContinuityPage> createState() => _ContinuityPageState();
}

class _ContinuityPageState extends State<ContinuityPage> {
  String _query = '';
  String? _category;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WebSocketService>();
    final items = ws.continuityItems.where(_matchesQuery).toList();
    final filtered =
        _category == null
            ? items
            : items.where((e) => e.category == _category).toList();

    final videos = filtered.where((e) => e.isVideo).toList();
    final clipboard = filtered.where((e) => !e.isVideo && !e.isFile).toList();
    final files = filtered.where((e) => e.isFile).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 880;
        final contentW =
            constraints.maxWidth < 1080 ? constraints.maxWidth : 1080.0;
        final colWidth = ((contentW - 40) / 2).clamp(120.0, 640.0);

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _Header(
                      count: ws.continuityCount,
                      connected: ws.state == DaemonLinkState.connected,
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _SearchBar(
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _CategoryChips(
                      counts: _countsByCategory(ws.continuityItems),
                      selected: _category,
                      onSelected: (c) => setState(() => _category = c),
                    ),
                  ),
                ),
                if (filtered.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(hasItems: ws.continuityCount == 0),
                  )
                else ...[
                  if (videos.isNotEmpty)
                    ..._section(
                      'Vidéos',
                      videos,
                      _VideoTile.new,
                      Icons.play_circle_fill,
                      const Color(0xFFFF5252),
                      wide,
                      colWidth,
                    ),
                  if (clipboard.isNotEmpty)
                    ..._section(
                      'Presse-papier',
                      clipboard,
                      _ClipboardTile.new,
                      Icons.content_paste,
                      AppColors.accent,
                      wide,
                      colWidth,
                    ),
                  if (files.isNotEmpty)
                    ..._section(
                      'Fichiers',
                      files,
                      _FileTile.new,
                      Icons.insert_drive_file,
                      AppColors.statusOrange,
                      wide,
                      colWidth,
                    ),
                ],
                const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
              ],
            ),
          ),
        );
      },
    );
  }

  Map<String, int> _countsByCategory(List<ContinuityItem> all) {
    return {
      'video': all.where((e) => e.isVideo).length,
      'presse-papier': all.where((e) => !e.isVideo && !e.isFile).length,
      'fichier': all.where((e) => e.isFile).length,
    };
  }

  bool _matchesQuery(ContinuityItem e) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return e.content.toLowerCase().contains(q) ||
        e.title.toLowerCase().contains(q) ||
        e.category.toLowerCase().contains(q);
  }

  List<Widget> _section(
    String title,
    List<ContinuityItem> items,
    Widget Function(ContinuityItem) tile,
    IconData icon,
    Color color,
    bool wide,
    double colWidth,
  ) {
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        sliver: SliverToBoxAdapter(
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${items.length}',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Divider(color: AppColors.divider, height: 1),
              ),
            ],
          ),
        ),
      ),
      if (wide)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final item in items)
                  SizedBox(width: colWidth, child: tile(item)),
              ],
            ),
          ),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => tile(items[i]),
          ),
        ),
    ];
  }
}

class _CategoryChips extends StatelessWidget {
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _CategoryChips({
    required this.counts,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final total = counts.values.fold(0, (a, b) => a + b);
    Widget chip(String? cat, String label, int n, IconData icon) {
      final active = selected == cat;
      final fg = active ? AppColors.background : AppColors.textPrimary;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          selected: active,
          onSelected: (_) => onSelected(active ? null : cat),
          avatar: Icon(
            icon,
            size: 15,
            color: active ? AppColors.background : AppColors.textSecondary,
          ),
          label: Text(
            '$label ($n)',
            style: TextStyle(
              fontSize: 12,
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
          selectedColor: AppColors.accent,
          backgroundColor: AppColors.card,
          side: BorderSide(
            color: active ? AppColors.accent : AppColors.divider,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip(null, 'Tout', total, Icons.view_agenda),
          chip('video', 'Vidéos', counts['video'] ?? 0, Icons.play_circle_fill),
          chip(
            'presse-papier',
            'Presse-papier',
            counts['presse-papier'] ?? 0,
            Icons.content_paste,
          ),
          chip(
            'fichier',
            'Fichiers',
            counts['fichier'] ?? 0,
            Icons.insert_drive_file,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int count;
  final bool connected;
  const _Header({required this.count, required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.accent.withValues(alpha: 0.18),
                  blurRadius: 18,
                  spreadRadius: -4,
                ),
              ],
            ),
            child: const Icon(Icons.devices, color: AppColors.accent, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Continuity',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  connected
                      ? 'Copie un lien sur ton PC, il apparait ici instantanement.'
                      : 'Connexion au daemon requise pour recevoir les elements.',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.accent,
                ),
              ),
              Text(
                'elements',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      style: const TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        hintText: 'Rechercher dans Continuity...',
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        prefixIcon: const Icon(
          Icons.search,
          color: AppColors.textSecondary,
          size: 20,
        ),
        filled: true,
        fillColor: AppColors.card,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasItems;
  const _EmptyState({required this.hasItems});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.card,
                shape: BoxShape.circle,
                border: Border.all(
                  color: hasItems
                      ? AppColors.divider
                      : AppColors.accent.withValues(alpha: 0.35),
                ),
                boxShadow: hasItems
                    ? null
                    : [
                        BoxShadow(
                          color: AppColors.accent.withValues(alpha: 0.10),
                          blurRadius: 26,
                          spreadRadius: -6,
                        ),
                      ],
              ),
              child: Icon(
                hasItems ? Icons.search_off : Icons.content_copy,
                color: hasItems
                    ? AppColors.textSecondary
                    : AppColors.accent,
                size: 36,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              hasItems ? 'Aucun resultat' : 'Tout commence sur ton PC',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              hasItems
                  ? 'Essaie un autre mot-cle.'
                  : 'Copie un lien, un texte ou un fichier sur ton PC :\nil apparait ici, classe automatiquement.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final (label, icon) = switch (source) {
      'clipboard' => ('Presse-papiers', Icons.content_paste_go),
      'extension' => ('Navigateur', Icons.public),
      'hotkey' => ('PC', Icons.desktop_windows),
      'manual' => ('Manuel', Icons.edit_note),
      _ => ('App', Icons.smartphone),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.divider.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: AppColors.textSecondary),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RelativeTime extends StatelessWidget {
  final DateTime at;
  const _RelativeTime({required this.at});

  @override
  Widget build(BuildContext context) {
    final diff = DateTime.now().difference(at);
    String label;
    if (diff.inSeconds < 60) {
      label = 'a l\'instant';
    } else if (diff.inMinutes < 60) {
      label = 'il y a ${diff.inMinutes} min';
    } else if (diff.inHours < 24) {
      label = 'il y a ${diff.inHours} h';
    } else {
      label =
          '${at.day.toString().padLeft(2, '0')}/${at.month.toString().padLeft(2, '0')} '
          '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    }
    return Text(
      label,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 11),
    );
  }
}

class _ItemActions extends StatelessWidget {
  final ContinuityItem item;
  final bool showOpen;
  final bool showEdit;
  final bool showCopy;
  const _ItemActions({
    required this.item,
    this.showOpen = false,
    this.showEdit = false,
    this.showCopy = false,
  });

  Future<void> _open(BuildContext context) async {
    final url = item.openUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossible d\'ouvrir ce lien')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.read<WebSocketService>();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showEdit)
          IconButton(
            tooltip: 'Editer et renvoyer au PC',
            icon: const Icon(
              Icons.edit_outlined,
              size: 19,
              color: AppColors.statusOrange,
            ),
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => FileEditorScreen(item: item),
                  ),
                ),
          ),
        if (showOpen)
          IconButton(
            tooltip: 'Ouvrir',
            icon: const Icon(
              Icons.open_in_new,
              size: 19,
              color: AppColors.accent,
            ),
            onPressed: () => _open(context),
          ),
        if (showCopy)
          IconButton(
            tooltip: 'Copier',
            icon: const Icon(Icons.copy, size: 19, color: AppColors.statusBlue),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: item.content));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copie dans le presse-papier')),
                );
              }
            },
          ),
        IconButton(
          tooltip: 'Supprimer',
          icon: const Icon(
            Icons.delete_outline,
            size: 19,
            color: AppColors.textSecondary,
          ),
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder:
                  (context) => AlertDialog(
                    backgroundColor: AppColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    title: const Text('Supprimer cet element ?'),
                    content: Text(
                      item.title.isEmpty ? item.content : item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Annuler'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.statusRed,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Supprimer'),
                      ),
                    ],
                  ),
            );
            if (confirmed == true) ws.deleteContinuityItem(item.id);
          },
        ),
      ],
    );
  }
}

class _ItemCard extends StatelessWidget {
  final ContinuityItem item;
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool showOpen;
  final bool showEdit;
  final bool showCopy;
  final VoidCallback? onTap;

  const _ItemCard({
    required this.item,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.showOpen = false,
    this.showEdit = false,
    this.showCopy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _SourceBadge(source: item.source),
                      _RelativeTime(at: item.createdAt),
                      if (item.syncedBack)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.statusGreen.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 12,
                                color: AppColors.statusGreen,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Renvoyé au PC',
                                style: TextStyle(
                                  color: AppColors.statusGreen,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          _ItemActions(
            item: item,
            showOpen: showOpen,
            showEdit: showEdit,
            showCopy: showCopy,
          ),
        ],
      ),
    );
  }
}

String _fmtDuration(int s) {
  if (s <= 0) return '';
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return (h > 0 ? '$h h ' : '') + (m > 0 || h > 0 ? '$m min ' : '') + '$sec s';
}

String _fileName(ContinuityItem item) {
  final path = item.filePath;
  if (path != null && path.isNotEmpty) {
    final seg = path.split('/').last;
    if (seg.isNotEmpty) return seg;
  }
  return item.title.isEmpty ? 'Fichier' : item.title;
}

class _VideoTile extends StatelessWidget {
  final ContinuityItem item;
  const _VideoTile(this.item);

  @override
  Widget build(BuildContext context) {
    final title = item.title.isNotEmpty ? item.title : item.content;
    final pos = _fmtDuration(item.positionS);
    final dur = _fmtDuration(item.durationS);
    final subtitle = dur.isNotEmpty ? 'YouTube · $pos / $dur' : 'Video YouTube';
    return _ItemCard(
      item: item,
      icon: Icons.play_circle_fill,
      color: const Color(0xFFFF5252),
      title: title,
      subtitle: subtitle,
      showOpen: true,
    );
  }
}

class _ClipboardTile extends StatelessWidget {
  final ContinuityItem item;
  const _ClipboardTile(this.item);

  @override
  Widget build(BuildContext context) {
    if (item.isLink) {
      final uri = Uri.tryParse(item.content.trim());
      final host = uri != null && uri.host.isNotEmpty ? uri.host : item.content;
      return _ItemCard(
        item: item,
        icon: Icons.link,
        color: AppColors.accent,
        title: item.title.isNotEmpty ? item.title : item.content,
        subtitle: host,
        showOpen: true,
        showCopy: true,
      );
    }
    return _ItemCard(
      item: item,
      icon: item.kind == 'code' ? Icons.code : Icons.notes,
      color: AppColors.statusBlue,
      title: item.title.isNotEmpty ? item.title : item.content,
      subtitle: 'Texte copie sur le PC',
      showCopy: true,
    );
  }
}

class _FileTile extends StatelessWidget {
  final ContinuityItem item;
  const _FileTile(this.item);

  @override
  Widget build(BuildContext context) {
    final subtitle = item.filePath ?? 'Fichier depuis le PC';
    return _ItemCard(
      item: item,
      icon: Icons.insert_drive_file,
      color: AppColors.statusOrange,
      title: _fileName(item),
      subtitle: subtitle,
      showEdit: true,
      onTap:
          () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => FileEditorScreen(item: item)),
          ),
    );
  }
}
