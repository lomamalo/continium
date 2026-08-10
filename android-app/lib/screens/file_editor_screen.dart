import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../main.dart';
import '../services/websocket_service.dart';

/// Full-screen editor for a file captured on the PC. Saves the edited
/// content back to the PC via the daemon (`continuity_back`).
class FileEditorScreen extends StatefulWidget {
  final ContinuityItem item;
  const FileEditorScreen({super.key, required this.item});

  @override
  State<FileEditorScreen> createState() => _FileEditorScreenState();
}

class _FileEditorScreenState extends State<FileEditorScreen> {
  late final TextEditingController _controller;
  bool _sending = false;

  String get _fileName {
    final path = widget.item.filePath;
    if (path != null && path.isNotEmpty) {
      final seg = path.split('/').last;
      if (seg.isNotEmpty) return seg;
    }
    return widget.item.title.isEmpty ? 'Fichier' : widget.item.title;
  }

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.content);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendBack() async {
    final ws = context.read<WebSocketService>();
    setState(() => _sending = true);
    ws.sendBack(widget.item.id, _controller.text);

    // The daemon answers with `file_backed` (or the item refresh); give it a
    // moment then report success.
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() => _sending = false);
    final path = widget.item.filePath;
    final target = path != null && path.isNotEmpty ? path : 'le tampon';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Envoyé vers $target')));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.item.filePath;
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Supprimer',
            icon: const Icon(
              Icons.delete_outline,
              color: AppColors.textSecondary,
            ),
            onPressed:
                () => context.read<WebSocketService>().deleteContinuityItem(
                  widget.item.id,
                ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (path != null && path.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      path,
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
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.4,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Edite le contenu...',
                      hintStyle: const TextStyle(
                        color: AppColors.textSecondary,
                      ),
                      filled: true,
                      fillColor: AppColors.card,
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
                        borderSide: const BorderSide(
                          color: AppColors.accent,
                          width: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _sending ? null : _sendBack,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.statusGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon:
                      _sending
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                          : const Icon(Icons.arrow_back, size: 18),
                  label: Text(_sending ? 'Envoi...' : 'Envoyer au PC'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
