import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rafraîchissement périodique économe : aucune requête quand l'application est en
/// arrière-plan, quand l'écran est caché (pause manuelle : onglet masqué) ou recouvert
/// par un autre écran ([canPoll]), ni quand le statut ne demande plus de suivi.
class SmartPoller {
  final Future<void> Function() onPoll;

  /// Intervalle selon le statut ; `null` (ou plus de 30 min) = pas de suivi.
  final Duration? Function(String status)? getInterval;

  /// Condition supplémentaire vérifiée à chaque échéance (ex. écran au premier plan).
  final bool Function()? canPoll;

  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  String _status = '';
  bool _stopped = true;
  bool _paused = false; // pause manuelle (onglet caché, écran recouvert)
  bool _background = false; // application en arrière-plan
  bool _polling = false; // une requête est en cours

  SmartPoller({required this.onPoll, this.getInterval, this.canPoll});

  /// Intervalle par défaut selon le statut d'une commande.
  static Duration? getDefaultInterval(String status) {
    if (const ['preparing', 'ready', 'delivering'].contains(status)) return const Duration(seconds: 5);
    if (const ['pending', 'confirmed'].contains(status)) return const Duration(seconds: 10);
    return null; // commande terminée : plus de suivi
  }

  Duration? _intervalFor(String status) {
    final d = getInterval != null ? getInterval!(status) : getDefaultInterval(status);
    if (d == null || d > const Duration(minutes: 30)) return null;
    return d;
  }

  static bool _foreground(AppLifecycleState? s) =>
      s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  /// Démarre le suivi (à appeler une fois, dans initState).
  void startPolling(String initialStatus) {
    _status = initialStatus;
    _stopped = false;
    _background = !_foreground(WidgetsBinding.instance.lifecycleState);
    _lifecycle ??= AppLifecycleListener(onStateChange: _onAppState);
    _schedule();
  }

  /// Arrête définitivement (dans dispose()).
  void stop() {
    _stopped = true;
    _cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// Suspend le suivi (onglet caché, écran poussé par-dessus).
  void pause() {
    _paused = true;
    _cancel();
  }

  /// Reprend le suivi ; [pollNow] : actualise tout de suite.
  void resume({bool pollNow = true}) {
    if (!_paused) return;
    _paused = false;
    if (pollNow) {
      this.pollNow();
    } else {
      _schedule();
    }
  }

  bool get isPaused => _paused;

  /// Nouveau statut : adapte le rythme (ou arrête le suivi pour une commande terminée).
  void updateStatus(String newStatus) {
    if (newStatus == _status || _stopped) return;
    _status = newStatus;
    _schedule();
  }

  /// Actualise immédiatement (si le suivi est actif), puis reprogramme.
  Future<void> pollNow() async {
    if (_stopped || _paused || _background || _polling) return;
    if (_intervalFor(_status) == null) return;
    _cancel();
    _polling = true;
    try {
      await onPoll();
    } catch (_) {
      // On réessaiera à la prochaine échéance.
    } finally {
      _polling = false;
    }
    _schedule();
  }

  void _onAppState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_background) return;
      _background = false;
      pollNow(); // retour dans l'application : données à jour tout de suite
    } else if (!_foreground(state)) {
      _background = true;
      _cancel();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _cancel();
    // Pendant une requête, c'est pollNow qui reprogramme à la fin.
    if (_stopped || _paused || _background || _polling) return;
    final interval = _intervalFor(_status);
    if (interval == null) return;
    _timer = Timer(interval, () {
      _timer = null;
      if (canPoll != null && !canPoll!()) {
        _schedule(); // écran recouvert : on attend sans requête
      } else {
        pollNow();
      }
    });
  }

  /// Intervalle actuel (null = pas de suivi).
  Duration? getCurrentInterval() => _intervalFor(_status);

  /// Vrai si une prochaine actualisation est programmée.
  bool get isPolling => _timer?.isActive ?? false;
}

/// Vrai si l'écran de [context] est celui affiché au premier plan (rien n'est poussé par-dessus).
bool isRouteOnTop(BuildContext context) {
  if (!context.mounted) return false;
  return ModalRoute.of(context)?.isCurrent ?? true;
}
