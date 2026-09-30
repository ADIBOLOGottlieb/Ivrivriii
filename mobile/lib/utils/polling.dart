import 'dart:async';

/// Smart polling manager that adjusts interval based on order status.
/// Reduces server load by polling less frequently for stable statuses.
class SmartPoller {
  Timer? _timer;
  final Duration Function(String status)? getInterval;
  final Future<void> Function() onPoll;
  String _lastStatus = '';

  SmartPoller({
    required this.onPoll,
    this.getInterval,
  });

  /// Get default poll interval based on order status.
  /// Priority levels: urgent (5s) > active (10s) > stable (no poll)
  static Duration getDefaultInterval(String status) {
    // Urgent: order is being prepared or delivered
    if (['preparing', 'ready', 'delivering'].contains(status)) {
      return const Duration(seconds: 5);
    }
    // Active: order just placed or confirmed
    if (['pending', 'confirmed'].contains(status)) {
      return const Duration(seconds: 10);
    }
    // Stable: order finished or cancelled - no polling needed
    return const Duration(hours: 1); // Effectively disabled
  }

  /// Start polling with adaptive interval.
  void startPolling(String initialStatus) {
    _lastStatus = initialStatus;
    _scheduleNextPoll();
  }

  /// Stop polling (call in dispose()).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Update status and restart polling with new interval if status changed.
  void updateStatus(String newStatus) {
    if (newStatus == _lastStatus) return;

    _lastStatus = newStatus;
    _timer?.cancel();

    // Only restart polling if still needed
    final interval = getInterval?.call(newStatus) ?? getDefaultInterval(newStatus);
    if (interval.inMinutes < 1) {
      _scheduleNextPoll();
    } else {
      // Stop polling for stable statuses
      stop();
    }
  }

  void _scheduleNextPoll() {
    final interval = getInterval?.call(_lastStatus) ?? getDefaultInterval(_lastStatus);

    // Skip polling for finished orders (1+ hour interval)
    if (interval.inMinutes > 30) {
      stop();
      return;
    }

    _timer = Timer(interval, () async {
      try {
        await onPoll();
        // Reschedule next poll
        _scheduleNextPoll();
      } catch (e) {
        // Continue polling on error
        _scheduleNextPoll();
      }
    });
  }

  /// Get current poll interval (for diagnostics).
  Duration getCurrentInterval() =>
      getInterval?.call(_lastStatus) ?? getDefaultInterval(_lastStatus);

  /// Check if polling is active.
  bool get isPolling => _timer?.isActive ?? false;
}

/// Batch request deduplicator - prevents duplicate API calls.
/// Useful when multiple widgets request the same data simultaneously.
class RequestDeduplicator<T> {
  final Map<String, Future<T>> _pending = {};

  /// Execute request only once if another is already pending with same key.
  Future<T> dedupe(String key, Future<T> Function() request) {
    if (_pending.containsKey(key)) {
      return _pending[key]!;
    }

    final future = request().then((result) {
      _pending.remove(key);
      return result;
    }).catchError((e) {
      _pending.remove(key);
      rethrow;
    });

    _pending[key] = future;
    return future;
  }

  /// Clear all pending requests.
  void clear() => _pending.clear();

  /// Check if specific request is pending.
  bool isPending(String key) => _pending.containsKey(key);
}

/// Debouncer for API calls triggered by user input.
/// Prevents excessive requests while user is typing/scrolling.
class Debouncer {
  Timer? _timer;
  final Duration delay;
  final Future<void> Function() onExecute;

  Debouncer({required this.delay, required this.onExecute});

  /// Schedule callback with debounce. Cancels previous if called again quickly.
  void call() {
    _timer?.cancel();
    _timer = Timer(delay, () async {
      try {
        await onExecute();
      } catch (e) {
        // Handle error silently or report to logging service
      }
    });
  }

  /// Cancel pending debounced call.
  void cancel() => _timer?.cancel();

  /// Dispose and cleanup.
  void dispose() => cancel();
}

/// Rate limiter for API calls.
/// Prevents too many requests to same endpoint in short time.
class RateLimiter {
  final Duration window;
  final int maxRequests;
  final List<DateTime> _requestTimes = [];

  RateLimiter({
    required this.window,
    required this.maxRequests,
  });

  /// Check if another request is allowed within rate limit.
  bool canMakeRequest() {
    final now = DateTime.now();
    // Remove old request times outside the window
    _requestTimes.removeWhere((t) => now.difference(t) > window);

    if (_requestTimes.length < maxRequests) {
      _requestTimes.add(now);
      return true;
    }
    return false;
  }

  /// Reset rate limiter.
  void reset() => _requestTimes.clear();

  /// Get remaining requests in current window.
  int getRemainingRequests() =>
      maxRequests - _requestTimes.length;

  /// Get time until next request allowed (or 0 if now).
  Duration getTimeUntilAvailable() {
    if (_requestTimes.isEmpty || _requestTimes.length < maxRequests) {
      return Duration.zero;
    }
    final oldestRequest = _requestTimes.first;
    final elapsed = DateTime.now().difference(oldestRequest);
    final remaining = window - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }
}
