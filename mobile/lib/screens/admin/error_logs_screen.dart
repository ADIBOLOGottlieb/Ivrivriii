import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../../services/admin_api.dart';
import '../../theme.dart';
import '../../utils/format.dart';
import '../../widgets/common.dart';
import 'admin_layout.dart';

/// Gérant : journal des erreurs (plantages de l'application et erreurs du serveur).
class ErrorLogsScreen extends StatefulWidget {
  const ErrorLogsScreen({super.key});

  @override
  State<ErrorLogsScreen> createState() => _ErrorLogsScreenState();
}

class _ErrorLogsScreenState extends State<ErrorLogsScreen> {
  static const _filters = <String?, String>{null: 'Toutes', 'app': 'App', 'server': 'Serveur'};

  String? _source;
  List<ErrorLogEntry>? _logs;
  Object? _error;
  int _gen = 0; // seule la dernière requête lancée est affichée

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    try {
      final logs = await fetchErrorLogs(source: _source);
      if (!mounted || gen != _gen) return;
      setState(() {
        _logs = logs;
        _error = null;
      });
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = e);
    }
  }

  void _select(String? source) {
    if (source == _source) return;
    setState(() {
      _source = source;
      _logs = null;
      _error = null;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final logs = _logs;
    return Scaffold(
      appBar: AppBar(
        title: const Text("Erreurs de l'app"),
        actions: [IconButton(tooltip: 'Actualiser', onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              children: [
                for (final f in _filters.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.value),
                      selected: _source == f.key,
                      showCheckmark: false,
                      selectedColor: AppColors.red,
                      backgroundColor: scheme.surface,
                      labelStyle: TextStyle(
                        color: _source == f.key ? Colors.white : scheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                      onSelected: (_) => _select(f.key),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: MaxContentWidth(
        child: RefreshIndicator(
          onRefresh: _load,
          child: logs == null
              ? (_error != null
                  ? ListView(children: [ErrorRetry(error: _error!, onRetry: _load)])
                  : const Center(child: CircularProgressIndicator()))
              : logs.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 60),
                      EmptyState(emoji: '🎉', title: 'Aucune erreur', message: 'Rien à signaler pour le moment.'),
                    ])
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                      itemCount: logs.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return Text(
                            '${logs.length} erreur${logs.length > 1 ? 's' : ''} (30 derniers jours au plus)',
                            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                          );
                        }
                        return _ErrorTile(entry: logs[i - 1]);
                      },
                    ),
        ),
      ),
    );
  }
}

class _ErrorTile extends StatelessWidget {
  final ErrorLogEntry entry;
  const _ErrorTile({required this.entry});

  String get _report => [
        '[${entry.source == 'server' ? 'Serveur' : 'App'}] ${formatDateTime(entry.createdAt)}',
        entry.message,
        if ((entry.context ?? '').isNotEmpty) 'Contexte : ${entry.context}',
        if ((entry.appVersion ?? '').isNotEmpty || (entry.platform ?? '').isNotEmpty)
          'Version : ${entry.appVersion ?? '?'} (${entry.platform ?? '?'})',
        if (entry.userId != null) 'Utilisateur n°${entry.userId}',
        if ((entry.stack ?? '').isNotEmpty) '\n${entry.stack}',
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final server = entry.source == 'server';
    final color = server ? (dark ? Colors.indigo.shade200 : Colors.indigo.shade600) : (dark ? scheme.primary : AppColors.red);
    final details = [
      timeAgo(entry.createdAt),
      if ((entry.context ?? '').isNotEmpty) entry.context!,
      if ((entry.platform ?? '').isNotEmpty) entry.platform!,
      if ((entry.appVersion ?? '').isNotEmpty) 'v${entry.appVersion}',
    ].join(' • ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Pas de traits au-dessus et en dessous du contenu déplié.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.14),
            child: Icon(server ? Icons.dns_rounded : Icons.phone_android_rounded, color: color, size: 20),
          ),
          title: Text(
            entry.message.isEmpty ? '(sans message)' : entry.message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface, fontSize: 14),
          ),
          subtitle: Text(details, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
          children: [
            SelectableText(entry.message, style: TextStyle(color: scheme.onSurface)),
            const SizedBox(height: 8),
            _info(context, 'Source', server ? 'Serveur' : 'Application'),
            _info(context, 'Date', formatDateTime(entry.createdAt)),
            if ((entry.context ?? '').isNotEmpty) _info(context, 'Contexte', entry.context!),
            if ((entry.appVersion ?? '').isNotEmpty) _info(context, 'Version', entry.appVersion!),
            if ((entry.platform ?? '').isNotEmpty) _info(context, 'Plateforme', entry.platform!),
            if (entry.userId != null) _info(context, 'Utilisateur', 'n°${entry.userId}'),
            const SizedBox(height: 10),
            if ((entry.stack ?? '').isNotEmpty) ...[
              Text("Pile d'appels", style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
              const SizedBox(height: 6),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      entry.stack!,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: scheme.onSurface, height: 1.35),
                    ),
                  ),
                ),
              ),
            ] else
              Text("Pas de pile d'appels", style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _report));
                  if (context.mounted) showMessage(context, 'Erreur copiée dans le presse-papiers');
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copier'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _info(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 92, child: Text(label, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))),
          Expanded(child: SelectableText(value, style: TextStyle(color: scheme.onSurface, fontSize: 13))),
        ],
      ),
    );
  }
}
