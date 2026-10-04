import 'package:flutter/material.dart';

import '../../models.dart';
import '../../models_admin.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Nombre maximal de plages par jour (même limite que le serveur).
const _maxRanges = 3;

/// Éditeur des horaires d'ouverture : pour chaque jour, 0 à 3 plages « 10:00 – 22:00 »
/// (« Fermé » sans plage). Les heures se choisissent avec le sélecteur 24 h ; « 24:00 » = minuit.
class OpeningHoursEditor extends StatelessWidget {
  final Map<String, List<List<String>>> hours;
  final ValueChanged<Map<String, List<List<String>>>> onChanged;

  const OpeningHoursEditor({super.key, required this.hours, required this.onChanged});

  List<List<String>> _day(String d) => hours[d] ?? const [];

  /// Copie modifiable des horaires avec [ranges] pour le jour [day].
  void _set(String day, List<List<String>> ranges) {
    onChanged({
      for (final d in AppSettings.weekDays)
        d: d == day ? ranges : [for (final r in _day(d)) [...r]],
    });
  }

  Future<String?> _pick(BuildContext context, String current, {required bool end}) async {
    final minutes = hhmmToMinutes(current) ?? (end ? 22 * 60 : 10 * 60);
    final picked = await showTimePicker(
      context: context,
      helpText: end ? 'Heure de fermeture' : "Heure d'ouverture",
      initialTime: TimeOfDay(hour: (minutes ~/ 60) % 24, minute: minutes % 60),
      initialEntryMode: TimePickerEntryMode.dial,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return null;
    final m = picked.hour * 60 + picked.minute;
    // Fermeture à 00:00 = minuit en fin de journée.
    return minutesToHhmm(end && m == 0 ? 1440 : m);
  }

  Future<void> _editRange(BuildContext context, String day, int index, {required bool end}) async {
    final ranges = [for (final r in _day(day)) [...r]];
    final value = await _pick(context, ranges[index][end ? 1 : 0], end: end);
    if (value == null) return;
    ranges[index][end ? 1 : 0] = value;
    _set(day, ranges);
  }

  void _addRange(BuildContext context, String day) {
    final ranges = [for (final r in _day(day)) [...r]];
    if (ranges.length >= _maxRanges) return;
    if (ranges.isEmpty) {
      ranges.add(['10:00', '22:00']);
    } else {
      // Nouvelle plage après la dernière (1 h d'écart, 3 h d'ouverture), si la journée le permet.
      final lastEnd = ranges.map((r) => hhmmToMinutes(r[1]) ?? 0).reduce((a, b) => a > b ? a : b);
      final start = lastEnd + 60;
      if (start >= 1440) {
        showMessage(context, 'Plus de place après ${ranges.last[1]} : modifiez les plages existantes', error: true);
        return;
      }
      ranges.add([minutesToHhmm(start), minutesToHhmm((start + 180).clamp(0, 1440))]);
    }
    _set(day, ranges);
  }

  void _removeRange(String day, int index) {
    final ranges = [for (final r in _day(day)) [...r]]..removeAt(index);
    _set(day, ranges);
  }

  void _applyToAll(BuildContext context, String day) {
    final source = _day(day);
    onChanged({
      for (final d in AppSettings.weekDays) d: [for (final r in source) [...r]],
    });
    showMessage(
      context,
      source.isEmpty
          ? 'Tous les jours sont maintenant fermés'
          : 'Horaires du ${weekDayLabels[day]!.toLowerCase()} appliqués à tous les jours',
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Column(
          children: [
            for (final (i, day) in AppSettings.weekDays.indexed) ...[
              if (i > 0) Divider(height: 12, color: scheme.outlineVariant),
              _dayRow(context, day, scheme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _dayRow(BuildContext context, String day, ColorScheme scheme) {
    final ranges = _day(day);
    final error = openingRangesError(ranges);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 86,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(weekDayLabels[day]!, style: TextStyle(fontWeight: FontWeight.w800, color: scheme.onSurface)),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ranges.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 4),
                  child: Text('Fermé', style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
                ),
              for (final (i, r) in ranges.indexed)
                Row(
                  children: [
                    _timeButton(context, r[0], () => _editRange(context, day, i, end: false)),
                    Text('–', style: TextStyle(color: scheme.onSurfaceVariant)),
                    _timeButton(context, r[1], () => _editRange(context, day, i, end: true)),
                    IconButton(
                      tooltip: 'Supprimer la plage',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(Icons.close_rounded, size: 18, color: scheme.onSurfaceVariant),
                      onPressed: () => _removeRange(day, i),
                    ),
                  ],
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(error, style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              Wrap(
                children: [
                  if (ranges.length < _maxRanges)
                    TextButton.icon(
                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      onPressed: () => _addRange(context, day),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Ajouter une plage'),
                    ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: scheme.onSurfaceVariant,
                    ),
                    onPressed: () => _applyToAll(context, day),
                    icon: const Icon(Icons.copy_all_rounded, size: 18),
                    label: const Text('Appliquer à tous les jours'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _timeButton(BuildContext context, String value, VoidCallback onTap) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: dark ? Theme.of(context).colorScheme.onSurface : AppColors.ink,
        ),
        onPressed: onTap,
        child: Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
      ),
    );
  }
}
