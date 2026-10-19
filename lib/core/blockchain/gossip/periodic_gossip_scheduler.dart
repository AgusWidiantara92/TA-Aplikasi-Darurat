/// Scheduler modular untuk rekonsiliasi periodik inventaris BlockDAG SiagaMesh (Stage 5E.4.6).
///
/// Bertanggung jawab untuk:
/// 1. Mengatur interval rekonsiliasi periodik (default awal: 30 detik) secara modular dan teruji.
/// 2. Mengisolasi penjadwalan hanya untuk peer 1-hop yang terhubung dengan sesi kompatibel.
/// 3. Menerapkan backoff terbatas bertahap pada kegagalan transport atau peer tidak merespons.
/// 4. Mendukung pengujian deterministik tanpa ketergantungan waktu nyata (fake clock & manual tick).
/// 5. Membersihkan timer secara ketat saat peer disconnect, engine disable/dispose, atau routing reset.
library;

import 'dart:async';

import 'gossip_constants.dart';

/// Konfigurasi parameter eksperimen rekonsiliasi periodik BlockDAG.
class PeriodicGossipConfig {
  /// Interval dasar rekonsiliasi inventaris periodik (default awal: 30 detik).
  final Duration interval;

  /// Batas minimum jeda backoff setelah kegagalan rekonsiliasi (default: 5 detik).
  final Duration minBackoff;

  /// Batas maksimum jeda backoff setelah kegagalan berulang (default: 120 detik / 2 menit).
  final Duration maxBackoff;

  /// Rentang maksimum jitter acak untuk mengurangi tabrakan permintaan serentak (default: 5 detik).
  final Duration jitterRange;

  /// Provider fungsi jitter deterministik khusus untuk pengujian (opsional).
  final Duration Function(String endpointId)? jitterProvider;

  /// Batas waktu timeout permintaan blok in-flight sebelum dianggap tidak merespons (default: 15 detik).
  final Duration requestTimeout;

  /// Batas waktu kedaluwarsa respons peer terhadap rekonsiliasi inventaris periodik (default: 15 detik).
  final Duration responseTimeout;

  /// Apakah scheduler otomatis menjalankan Timer periodic di latar belakang (default: true).
  /// Disetel false pada unit/integration test untuk pengujian deterministik manual tanpa kebocoran timer.
  final bool autoStartTimer;

  const PeriodicGossipConfig({
    this.interval = kDefaultPeriodicGossipInterval,
    this.minBackoff = kMinPeriodicGossipBackoff,
    this.maxBackoff = kMaxPeriodicGossipBackoff,
    this.jitterRange = kDefaultPeriodicGossipJitterRange,
    this.jitterProvider,
    this.requestTimeout = kGossipRequestTimeout,
    this.responseTimeout = kPeriodicGossipResponseTimeout,
    this.autoStartTimer = true,
  });

  /// Menghitung durasi jeda backoff secara bertahap dan terbatas berdasarkan jumlah kegagalan beruntun.
  ///
  /// Rumus bounded exponential backoff:
  /// `delay = min(minBackoff * 2^(failures - 1), maxBackoff)`
  Duration computeBackoff(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    final shift = (consecutiveFailures - 1).clamp(0, 30);
    final ms = minBackoff.inMilliseconds * (1 << shift);
    if (ms >= maxBackoff.inMilliseconds || ms <= 0) {
      return maxBackoff;
    }
    return Duration(milliseconds: ms);
  }

  /// Menghitung durasi jitter untuk endpoint tertentu agar tidak memicu sinkronisasi serentak.
  Duration computeJitter(String endpointId) {
    if (jitterProvider != null) {
      return jitterProvider!(endpointId);
    }
    if (jitterRange <= Duration.zero) {
      return Duration.zero;
    }
    final seed = endpointId.hashCode.abs();
    return Duration(milliseconds: seed % (jitterRange.inMilliseconds + 1));
  }
}

/// Layanan scheduler modular pengatur frekuensi rekonsiliasi inventaris BlockDAG.
class PeriodicGossipScheduler {
  final PeriodicGossipConfig config;
  final Future<bool> Function(String endpointId, [DateTime? now])
  onReconcilePeer;
  final List<String> Function() getEligibleEndpoints;
  final DateTime Function() nowProvider;

  bool _isRunning = false;
  bool _isDisposed = false;
  final Map<String, Timer> _peerTimers = {};
  final Map<String, Timer> _responseTimeoutTimers = {};

  PeriodicGossipScheduler({
    this.config = const PeriodicGossipConfig(),
    required this.onReconcilePeer,
    required this.getEligibleEndpoints,
    DateTime Function()? nowProvider,
  }) : nowProvider = nowProvider ?? (() => DateTime.now().toUtc());

  /// Status apakah scheduler sedang aktif berjalan.
  bool get isRunning => _isRunning;

  /// Status apakah scheduler telah dimatikan secara permanen.
  bool get isDisposed => _isDisposed;

  /// Jumlah timer aktif yang sedang terpasang untuk masing-masing peer.
  int get activeTimersCount => _peerTimers.length;

  /// Jumlah timer timeout respons rekonsiliasi yang sedang aktif berjalan.
  int get activeResponseTimeoutTimersCount => _responseTimeoutTimers.length;

  /// Total seluruh timer aktif (peer schedule + response timeout).
  int get totalActiveTimersCount =>
      _peerTimers.length + _responseTimeoutTimers.length;

  /// Memulai scheduler periodik untuk seluruh peer yang memenuhi syarat.
  void start() {
    if (_isDisposed) return;
    if (_isRunning) return;
    _isRunning = true;

    if (config.autoStartTimer) {
      for (final endpointId in getEligibleEndpoints()) {
        schedulePeer(endpointId);
      }
    }
  }

  /// Menghentikan scheduler periodik dan membatalkan seluruh timer yang sedang berjalan.
  void stop() {
    _isRunning = false;
    for (final timer in _peerTimers.values) {
      timer.cancel();
    }
    _peerTimers.clear();
    for (final timer in _responseTimeoutTimers.values) {
      timer.cancel();
    }
    _responseTimeoutTimers.clear();
  }

  /// Menjadwalkan eksekusi rekonsiliasi berikutnya untuk satu peer tertentu.
  void schedulePeer(String endpointId, [Duration? delay]) {
    _peerTimers[endpointId]?.cancel();
    _peerTimers.remove(endpointId);

    if (!_isRunning || _isDisposed || !config.autoStartTimer) return;

    final effectiveDelay =
        delay ?? (config.interval + config.computeJitter(endpointId));
    _peerTimers[endpointId] = Timer(effectiveDelay, () async {
      _peerTimers.remove(endpointId);
      if (!_isRunning || _isDisposed) return;
      await onReconcilePeer(endpointId, nowProvider());
    });
  }

  /// Menjadwalkan timer batas waktu respons rekonsiliasi untuk peer tertentu jika [autoStartTimer] aktif.
  void scheduleResponseTimeout(
    String endpointId,
    Duration timeout,
    void Function() onTimeout,
  ) {
    _responseTimeoutTimers[endpointId]?.cancel();
    _responseTimeoutTimers.remove(endpointId);

    if (!_isRunning || _isDisposed || !config.autoStartTimer) return;

    _responseTimeoutTimers[endpointId] = Timer(timeout, () {
      _responseTimeoutTimers.remove(endpointId);
      if (!_isRunning || _isDisposed) return;
      onTimeout();
    });
  }

  /// Membatalkan timer batas waktu respons rekonsiliasi untuk peer tertentu.
  void cancelResponseTimeout(String endpointId) {
    _responseTimeoutTimers[endpointId]?.cancel();
    _responseTimeoutTimers.remove(endpointId);
  }

  /// Membatalkan jadwal rekonsiliasi dan timer timeout untuk satu peer tertentu (misal saat terputus).
  void cancelPeer(String endpointId) {
    _peerTimers[endpointId]?.cancel();
    _peerTimers.remove(endpointId);
    cancelResponseTimeout(endpointId);
  }

  /// Notifikasi bahwa peer baru telah menyelesaikan handshake awal dan siap untuk rekonsiliasi periodik.
  void onPeerReady(String endpointId, [Duration? initialDelay]) {
    if (!_isRunning || _isDisposed) return;
    schedulePeer(endpointId, initialDelay);
  }

  /// Notifikasi bahwa peer telah terputus (disconnected / rejected).
  void onPeerDisconnected(String endpointId) {
    cancelPeer(endpointId);
  }

  /// Mengeksekusi satu tick rekonsiliasi periodik untuk seluruh endpoint yang memenuhi syarat.
  ///
  /// Berguna untuk pengujian deterministik dan pemanggilan terkontrol.
  Future<void> tick([DateTime? now]) async {
    if (!_isRunning || _isDisposed) return;
    final currentTime = now ?? nowProvider();
    final endpoints = getEligibleEndpoints();
    for (final endpointId in endpoints) {
      if (!_isRunning || _isDisposed) break;
      await onReconcilePeer(endpointId, currentTime);
    }
  }

  /// Membersihkan seluruh resource scheduler secara permanen.
  void dispose() {
    _isDisposed = true;
    stop();
  }
}
