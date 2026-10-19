import 'dart:async';
import 'dart:convert';

/// Jenis peristiwa dalam siklus hidup paket perutean eksperimental.
enum MeshExperimentEventType {
  created,
  sentToTransport,
  received,
  forwarded,
  queued,
  expired,
  rejected,
  idsDetection,
}

/// Representasi data satu peristiwa eksperimen perutean terkendali SiagaMesh.
///
/// Menyimpan metadata teknis pengujian secara terstruktur tanpa mencatat isi chat pribadi,
/// token, atau kredensial pengguna (hanya data sintetis dan metadata envelope).
class MeshExperimentEvent {
  final String eventId;
  final String runId;
  final String testType;
  final String envelopeId;
  final String messageId;
  final String senderId;
  final String recipientId;
  final MeshExperimentEventType eventType;

  /// Waktu lokal perangkat saat peristiwa terjadi (Wall-Clock lokal).
  /// PERINGATAN: Jangan bandingkan langsung selisih timestamp ini antar-dua perangkat
  /// untuk mengukur latensi satu arah tanpa sinkronisasi jam yang terverifikasi.
  final DateTime localTimestamp;

  /// Jam monotonik lokal (mikrodetik sejak logger dimulai).
  /// Berguna untuk pengukuran durasi lokal (antrean, pemrosesan, atau RTT probe)
  /// yang bebas dari pergeseran jam sistem (clock skew).
  final int monotonicMicros;

  final int hopCount;
  final List<String> routeTrace;
  final String connectionStatus;
  final int activeNeighborCount;
  final String? failureReason;
  final String? outcome;
  final Map<String, dynamic>? syntheticMetadata;

  const MeshExperimentEvent({
    required this.eventId,
    required this.runId,
    required this.testType,
    required this.envelopeId,
    required this.messageId,
    required this.senderId,
    required this.recipientId,
    required this.eventType,
    required this.localTimestamp,
    required this.monotonicMicros,
    required this.hopCount,
    required this.routeTrace,
    required this.connectionStatus,
    required this.activeNeighborCount,
    this.failureReason,
    this.outcome,
    this.syntheticMetadata,
  });

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'runId': runId,
    'testType': testType,
    'envelopeId': envelopeId,
    'messageId': messageId,
    'senderId': senderId,
    'recipientId': recipientId,
    'eventType': eventType.name,
    'localTimestampMs': localTimestamp.millisecondsSinceEpoch,
    'localTimestampIso': localTimestamp.toIso8601String(),
    'monotonicMicros': monotonicMicros,
    'hopCount': hopCount,
    'routeTrace': routeTrace,
    'connectionStatus': connectionStatus,
    'activeNeighborCount': activeNeighborCount,
    'failureReason': failureReason ?? '',
    'outcome': outcome ?? '',
    'syntheticMetadata': syntheticMetadata ?? {},
  };

  /// Baris CSV untuk ekspor data eksperimen.
  String toCsvRow() {
    final traceStr = '"${routeTrace.join(';')}"';
    final safeReason = failureReason ?? '';
    final safeOutcome = outcome ?? '';
    return '$eventId,$runId,$testType,$envelopeId,$messageId,$senderId,$recipientId,${eventType.name},${localTimestamp.millisecondsSinceEpoch},${localTimestamp.toIso8601String()},$monotonicMicros,$hopCount,$traceStr,$connectionStatus,$activeNeighborCount,$safeReason,$safeOutcome';
  }

  static const String csvHeader =
      'eventId,runId,testType,envelopeId,messageId,senderId,recipientId,eventType,localTimestampMs,localTimestampIso,monotonicMicros,hopCount,routeTrace,connectionStatus,activeNeighborCount,failureReason,outcome';

  @override
  String toString() =>
      'MeshExperimentEvent(run: $runId, type: ${eventType.name}, msg: $messageId, hops: $hopCount, outcome: $outcome)';
}

/// Logger eksperimen MANET untuk pencatatan metrik terkendali (PDR, status hop, deduplikasi, buffer).
///
/// Dirancang berbobot ringan, non-blocking, dengan kapasitas memori terbatas (bounded ring buffer),
/// serta mendukung ekspor CSV/JSON untuk pengambilan data offline dari perangkat fisik.
class MeshExperimentLogger {
  static const int defaultMaxEvents = 1000;

  final int maxEvents;
  final Stopwatch _stopwatch = Stopwatch()..start();
  final List<MeshExperimentEvent> _events = [];
  final StreamController<MeshExperimentEvent> _controller =
      StreamController<MeshExperimentEvent>.broadcast();

  String activeRunId;
  String activeTestType;
  int _eventCounter = 0;

  MeshExperimentLogger({
    this.maxEvents = defaultMaxEvents,
    this.activeRunId = 'RUN-INIT',
    this.activeTestType = 'GENERAL',
  });

  /// Mencatat peristiwa baru ke buffer eksperimen.
  void log({
    required String envelopeId,
    required String messageId,
    required String senderId,
    required String recipientId,
    required MeshExperimentEventType eventType,
    required int hopCount,
    required List<String> routeTrace,
    required String connectionStatus,
    required int activeNeighborCount,
    String? runId,
    String? testType,
    String? failureReason,
    String? outcome,
    Map<String, dynamic>? syntheticMetadata,
  }) {
    _eventCounter++;
    final event = MeshExperimentEvent(
      eventId: 'evt-$_eventCounter',
      runId: runId ?? activeRunId,
      testType: testType ?? activeTestType,
      envelopeId: envelopeId,
      messageId: messageId,
      senderId: senderId,
      recipientId: recipientId,
      eventType: eventType,
      localTimestamp: DateTime.now(),
      monotonicMicros: _stopwatch.elapsedMicroseconds,
      hopCount: hopCount,
      routeTrace: List<String>.from(routeTrace),
      connectionStatus: connectionStatus,
      activeNeighborCount: activeNeighborCount,
      failureReason: failureReason,
      outcome: outcome,
      syntheticMetadata: syntheticMetadata,
    );

    if (_events.length >= maxEvents) {
      _events.removeAt(0); // Buang peristiwa tertua jika buffer meluap
    }
    _events.add(event);

    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Mencatat peristiwa klasifikasi/alarm deteksi IDS ke dalam log eksperimen.
  void logIdsDetection({
    required String targetNodeId,
    required String observerNodeId,
    required String status,
    required String reason,
    required int totalExpected,
    required int totalConfirmed,
    required int totalUnconfirmed,
    required int totalLinkFailures,
    required int totalProtocolDrops,
    required double observedDropRate,
    required Map<String, dynamic> thresholdConfig,
    String? runId,
    String? simulationGroundTruth,
  }) {
    _eventCounter++;
    final syntheticMeta = <String, dynamic>{
      'detectionStatus': status,
      'targetNodeId': targetNodeId,
      'observerNodeId': observerNodeId,
      'classificationReason': reason,
      'totalExpected': totalExpected,
      'totalConfirmed': totalConfirmed,
      'totalUnconfirmed': totalUnconfirmed,
      'totalLinkFailures': totalLinkFailures,
      'totalProtocolDrops': totalProtocolDrops,
      'observedDropRate': observedDropRate,
      'thresholdConfig': thresholdConfig,
    };
    if (simulationGroundTruth != null) {
      syntheticMeta['simulationGroundTruth'] = simulationGroundTruth;
    }

    final event = MeshExperimentEvent(
      eventId: 'ids-$_eventCounter',
      runId: runId ?? activeRunId,
      testType: activeTestType,
      envelopeId: 'IDS-$targetNodeId-$_eventCounter',
      messageId: 'STATUS-$status',
      senderId: observerNodeId,
      recipientId: targetNodeId,
      eventType: MeshExperimentEventType.idsDetection,
      localTimestamp: DateTime.now(),
      monotonicMicros: _stopwatch.elapsedMicroseconds,
      hopCount: 0,
      routeTrace: [observerNodeId, targetNodeId],
      connectionStatus: 'ACTIVE',
      activeNeighborCount: 1,
      failureReason: reason,
      outcome: status,
      syntheticMetadata: syntheticMeta,
    );

    if (_events.length >= maxEvents) {
      _events.removeAt(0);
    }
    _events.add(event);

    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Memulai sesi eksperimen baru dengan runId dan jenis pengujian tertentu.
  void startRun({required String runId, required String testType}) {
    activeRunId = runId;
    activeTestType = testType;
  }

  /// Mengambil seluruh peristiwa yang telah tercatat.
  List<MeshExperimentEvent> get events => List.unmodifiable(_events);

  /// Stream pembaruan peristiwa real-time untuk pemantauan UI jika diperlukan.
  Stream<MeshExperimentEvent> get eventsStream => _controller.stream;

  /// Mengambil daftar peristiwa yang sesuai dengan `runId`.
  List<MeshExperimentEvent> getEventsForRun(String runId) {
    return _events.where((e) => e.runId == runId).toList();
  }

  /// Menghitung total pesan unik yang dikirimkan oleh node sumber pada sesi tertentu.
  int countUniqueSentMessages(String runId) {
    final runEvents = getEventsForRun(runId);
    final sentMessageIds = <String>{};
    for (final evt in runEvents) {
      if (evt.eventType == MeshExperimentEventType.created ||
          evt.eventType == MeshExperimentEventType.sentToTransport) {
        sentMessageIds.add(evt.messageId);
      }
    }
    return sentMessageIds.length;
  }

  /// Menghitung total pesan unik yang berhasil diterima di tujuan pada sesi tertentu.
  int countUniqueReceivedMessages(String runId) {
    final runEvents = getEventsForRun(runId);
    final receivedMessageIds = <String>{};
    for (final evt in runEvents) {
      if (evt.eventType == MeshExperimentEventType.received &&
          evt.outcome == 'DELIVERED_TO_APP') {
        receivedMessageIds.add(evt.messageId);
      }
    }
    return receivedMessageIds.length;
  }

  /// Menghitung Packet Delivery Ratio (PDR) untuk suatu sesi lokal jika kedua peristiwa tercatat
  /// (atau digunakan pada pengujian simulasi multi-node).
  double calculateLocalPdr(String runId) {
    final sent = countUniqueSentMessages(runId);
    if (sent == 0) return 0.0;
    final received = countUniqueReceivedMessages(runId);
    return (received / sent) * 100.0;
  }

  /// Ekspor seluruh log ke format string CSV.
  String toCsv({String? runId}) {
    final targetEvents = runId == null ? _events : getEventsForRun(runId);
    final buffer = StringBuffer();
    buffer.writeln(MeshExperimentEvent.csvHeader);
    for (final evt in targetEvents) {
      buffer.writeln(evt.toCsvRow());
    }
    return buffer.toString();
  }

  /// Ekspor log ke format string JSON.
  String toJsonString({String? runId}) {
    final targetEvents = runId == null ? _events : getEventsForRun(runId);
    return jsonEncode(targetEvents.map((e) => e.toJson()).toList());
  }

  void clear() {
    _events.clear();
  }

  void dispose() {
    _controller.close();
  }
}
