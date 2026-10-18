import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../features/chat/data/repositories/chat_repository.dart';
import '../../features/chat/models/chat_message.dart';
import '../transport/mesh_transport.dart';
import 'deduplication_cache.dart';
import 'message_envelope.dart';
import 'neighbor_table.dart';
import 'node_identity.dart';
import 'store_and_forward_queue.dart';

/// Mesin perutean dan penerusan pesan multi-hop MANET SiagaMesh.
///
/// Bertanggung jawab atas:
/// - Handshake dan pemetaan endpoint transport ke identitas node aplikasi.
/// - Validasi envelope, batas hop (TTL), dan pencegahan loop (*route trace*).
/// - Deduplikasi pesan berbasis LRU cache (500 ID).
/// - Penerusan terkontrol (*controlled flooding*) tanpa memantulkan pesan ke asal.
/// - Penyimpanan sementara (*store-and-forward*) saat tetangga belum tersedia.
class ManetRoutingEngine {
  final MeshTransport transport;
  final NodeIdentityManager identityManager;
  final NeighborTable neighborTable;
  final DeduplicationCache dedupCache;
  final StoreAndForwardQueue storeAndForwardQueue;
  final ChatRepository? repository;

  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  StreamSubscription<TransportPayload>? _payloadSub;

  final StreamController<MessageEnvelope> _incomingMessagesController =
      StreamController<MessageEnvelope>.broadcast();
  final StreamController<MessageEnvelope> _forwardedMessagesController =
      StreamController<MessageEnvelope>.broadcast();

  ManetRoutingEngine({
    required this.transport,
    required this.identityManager,
    NeighborTable? neighborTable,
    DeduplicationCache? dedupCache,
    StoreAndForwardQueue? storeAndForwardQueue,
    this.repository,
  }) : neighborTable = neighborTable ?? NeighborTable(),
       dedupCache = dedupCache ?? DeduplicationCache(),
       storeAndForwardQueue = storeAndForwardQueue ?? StoreAndForwardQueue() {
    _initListeners();
  }

  void _initListeners() {
    _eventsSub = transport.connectionEventsStream.listen(
      _handleConnectionEvent,
    );
    _payloadSub = transport.payloadStream.listen(_handleIncomingPayload);
  }

  String get localNodeId => identityManager.localNodeId;
  String get localNodeName => identityManager.localNodeName;

  /// Stream pesan masuk yang tujuannya adalah node lokal ini atau siaran umum.
  Stream<MessageEnvelope> get incomingMessagesStream =>
      _incomingMessagesController.stream;

  /// Stream pesan yang berhasil diteruskan (*relayed*) oleh node ini sebagai perantara.
  Stream<MessageEnvelope> get forwardedMessagesStream =>
      _forwardedMessagesController.stream;

  // --- Penanganan Peristiwa Koneksi Transport ---

  void _handleConnectionEvent(TransportConnectionEvent event) async {
    if (event.status == PeerConnectionStatus.connected) {
      neighborTable.registerConnectedEndpoint(
        endpointId: event.endpointId,
        endpointName: event.endpointName,
      );

      // Kirim pesan handshake aplikasi untuk mengidentifikasi node ID lokal
      await _sendHandshake(event.endpointId);

      // Coba kirimkan pesan yang tertunda di antrean store-and-forward
      _flushQueueForEndpoint(event.endpointId);
    } else if (event.status == PeerConnectionStatus.disconnected ||
        event.status == PeerConnectionStatus.rejected) {
      neighborTable.markDisconnected(event.endpointId);
    }
  }

  Future<void> _sendHandshake(String endpointId) async {
    final handshake = MessageEnvelope(
      envelopeId:
          'hs-$localNodeId-$endpointId-${DateTime.now().millisecondsSinceEpoch}',
      type: MessageEnvelope.typeHandshake,
      senderId: localNodeId,
      senderName: localNodeName,
      recipientId: 'BROADCAST',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      ttl: 1, // Handshake hanya untuk tetangga langsung (1-hop)
      hopCount: 0,
      routeTrace: [localNodeId],
      payload: {'nodeId': localNodeId, 'nodeName': localNodeName},
    );

    try {
      await transport.sendBytes(
        endpointId: endpointId,
        bytes: handshake.toBytes(),
      );
    } catch (e) {
      debugPrint('[RoutingEngine] Gagal mengirim handshake: $e');
    }
  }

  // --- Penanganan Payload Nirkabel Masuk ---

  void _handleIncomingPayload(TransportPayload payload) async {
    final envelope = MessageEnvelope.fromBytes(payload.bytes);
    if (envelope == null) {
      // Tolak data korup, tidak lengkap, atau versi tidak didukung secara aman
      return;
    }

    // 1. Tangani Handshake Identitas
    if (envelope.type == MessageEnvelope.typeHandshake) {
      final remoteNodeId =
          envelope.payload['nodeId'] as String? ?? envelope.senderId;
      final remoteNodeName =
          envelope.payload['nodeName'] as String? ?? envelope.senderName;

      neighborTable.mapIdentity(
        endpointId: payload.endpointId,
        nodeId: remoteNodeId,
        nodeName: remoteNodeName,
      );

      // Setelah identitas node terpetakan, coba flush antrean store-and-forward
      _flushQueueForNode(remoteNodeId, payload.endpointId);
      return;
    }

    // 2. Tangani Pesan Obrolan (CHAT_MESSAGE)
    if (envelope.type == MessageEnvelope.typeChat) {
      // Aturan A: Pemeriksaan Deduplikasi
      if (dedupCache.checkAndAdd(envelope.envelopeId)) {
        // Pesan duplikat telah dilihat sebelumnya, hentikan penyebaran!
        return;
      }

      // Aturan B: Pencegahan Loop Perutean
      if (envelope.routeTrace.contains(localNodeId)) {
        // Pesan sudah pernah melewati node ini sebelumnya, hentikan loop!
        return;
      }

      // Aturan C: Pemeriksaan Batas Hop / TTL
      if (envelope.ttl <= 0) {
        // Masa hidup paket habis, buang!
        return;
      }

      // Aturan D: Penentuan Tujuan
      final isForMe = envelope.recipientId == localNodeId;
      final isBroadcast = envelope.recipientId == 'BROADCAST';

      if (isForMe || isBroadcast) {
        // Node ini adalah penerima tujuan akhir
        await _deliverToLocalApp(envelope, isBroadcast: isBroadcast);
        _incomingMessagesController.add(envelope);

        // Jika pesan siaran (BROADCAST), teruskan juga ke tetangga lain jika TTL masih tersisa
        if (isBroadcast && envelope.ttl > 1) {
          await _forwardToOtherNeighbors(
            envelope: envelope,
            sourceEndpointId: payload.endpointId,
          );
        }
      } else {
        // Node ini HANYA PERANTARA (Relay Node)!
        // Wajib: Jangan mencampur pesan dengan percakapan lokal node perantara
        if (envelope.ttl > 1) {
          await _forwardToOtherNeighbors(
            envelope: envelope,
            sourceEndpointId: payload.endpointId,
          );
        }
      }
    }
  }

  /// Meneruskan pesan ke tetangga yang memenuhi syarat.
  Future<void> _forwardToOtherNeighbors({
    required MessageEnvelope envelope,
    required String sourceEndpointId,
  }) async {
    final forwardedEnvelope = envelope.createForwardedCopy(localNodeId);
    final activeNeighbors = neighborTable.activeNeighbors;

    // Jika tujuan unicast langsung terhubung, kirimkan langsung ke endpoint tersebut
    final directEndpointId = neighborTable.getEndpointIdForNode(
      envelope.recipientId,
    );
    if (directEndpointId != null && directEndpointId != sourceEndpointId) {
      try {
        await transport.sendBytes(
          endpointId: directEndpointId,
          bytes: forwardedEnvelope.toBytes(),
        );
        _forwardedMessagesController.add(forwardedEnvelope);
        return;
      } catch (e) {
        debugPrint(
          '[RoutingEngine] Gagal forward langsung ke $directEndpointId: $e',
        );
      }
    }

    // Controlled Flooding: Kirim ke semua tetangga aktif selain pengirim asal
    // dan selain node yang sudah tercatat di route trace
    bool anySent = false;
    for (final neighbor in activeNeighbors) {
      if (neighbor.endpointId == sourceEndpointId) {
        // Jangan mengirim kembali ke peer asal yang baru saja mengirimkan paket!
        continue;
      }
      if (forwardedEnvelope.routeTrace.contains(neighbor.nodeId)) {
        // Jangan mengirim ke node yang sudah ada di jejak rute!
        continue;
      }

      try {
        final sent = await transport.sendBytes(
          endpointId: neighbor.endpointId,
          bytes: forwardedEnvelope.toBytes(),
        );
        if (sent) anySent = true;
      } catch (_) {}
    }

    if (anySent) {
      _forwardedMessagesController.add(forwardedEnvelope);
    } else {
      // Jika tidak ada tetangga lain yang dapat dijangkau, simpan di buffer antrean
      storeAndForwardQueue.enqueue(forwardedEnvelope);
    }
  }

  /// Menyampaikan pesan yang ditujukan untuk node ini ke ChatRepository lokal.
  Future<void> _deliverToLocalApp(
    MessageEnvelope envelope, {
    required bool isBroadcast,
  }) async {
    if (repository == null) return;

    final messageId =
        envelope.payload['messageId'] as String? ?? envelope.envelopeId;
    final text = envelope.payload['text'] as String? ?? '';
    final timeStr = envelope.payload['time'] as String? ?? 'Baru saja';
    final isEmergency = envelope.payload['isEmergency'] as bool? ?? false;

    TelemetryData? telemetry;
    if (envelope.payload['telemetry'] != null &&
        envelope.payload['telemetry'] is Map<String, dynamic>) {
      try {
        telemetry = TelemetryData.fromJson(
          envelope.payload['telemetry'] as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    final hopInfo = envelope.hopCount > 0
        ? 'Relay melalui ${envelope.hopCount} hop: [${envelope.routeTrace.join(' → ')}]'
        : 'Transmisi 1-Hop Langsung';

    final chatMessage = ChatMessage(
      id: messageId,
      senderName: envelope.senderName,
      text: text,
      time: timeStr,
      isMe: false,
      isEmergency: isEmergency,
      relayInfo: hopInfo,
      statusText: isBroadcast
          ? 'Diterima (Siaran Multi-Hop)'
          : (envelope.hopCount > 0
                ? 'Diterima (${envelope.hopCount}-Hop Relay)'
                : 'Diterima (1-Hop Langsung)'),
      telemetryData: telemetry,
    );

    if (isBroadcast) {
      await repository!.saveMessage('broadcast-all', chatMessage);
    } else {
      final conv = await repository!.getOrCreateConversationForNode(
        nodeId: envelope.senderId,
        nodeName: envelope.senderName,
        isEmergency: isEmergency,
        isConnected: true,
      );
      await repository!.saveMessage(conv.id, chatMessage);
    }
  }

  // --- Pengiriman Pesan Baru dari Node Lokal ---

  /// Mengirimkan pesan baru dari node lokal menuju tujuan tertentu atau siaran umum.
  Future<MessageEnvelope> sendChatMessage({
    required String recipientNodeId,
    required String text,
    TelemetryData? telemetry,
    bool isEmergency = false,
  }) async {
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final randomSuffix = Random().nextInt(10000);
    final envelopeId =
        'env-${now.millisecondsSinceEpoch}-$localNodeId-$randomSuffix';
    final messageId = 'msg-${now.millisecondsSinceEpoch}-$randomSuffix';

    final envelope = MessageEnvelope(
      envelopeId: envelopeId,
      type: MessageEnvelope.typeChat,
      senderId: localNodeId,
      senderName: localNodeName,
      recipientId: recipientNodeId,
      createdAt: now.millisecondsSinceEpoch,
      ttl: MessageEnvelope.defaultTtl,
      hopCount: 0,
      routeTrace: [localNodeId],
      payload: {
        'messageId': messageId,
        'text': text,
        'time': timeStr,
        'isEmergency': isEmergency,
        'telemetry': telemetry?.toJson(),
      },
    );

    // Catat ke deduplikasi lokal agar pesan kita sendiri tidak diproses ulang jika terpantul
    dedupCache.add(envelopeId);

    // Kirim ke transport
    final bytes = envelope.toBytes();
    final activeNeighbors = neighborTable.activeNeighbors;

    bool sentAnywhere = false;

    // Jika tujuan langsung terhubung
    final directEndpointId = neighborTable.getEndpointIdForNode(
      recipientNodeId,
    );
    if (directEndpointId != null) {
      try {
        final ok = await transport.sendBytes(
          endpointId: directEndpointId,
          bytes: bytes,
        );
        if (ok) sentAnywhere = true;
      } catch (_) {}
    } else if (activeNeighbors.isNotEmpty) {
      // Flooding ke seluruh tetangga aktif
      for (final neighbor in activeNeighbors) {
        try {
          final ok = await transport.sendBytes(
            endpointId: neighbor.endpointId,
            bytes: bytes,
          );
          if (ok) sentAnywhere = true;
        } catch (_) {}
      }
    }

    if (!sentAnywhere) {
      // Tidak ada tetangga aktif yang menerima, simpan ke antrean store-and-forward
      storeAndForwardQueue.enqueue(envelope);
    }

    return envelope;
  }

  void _flushQueueForEndpoint(String endpointId) {
    final pending = storeAndForwardQueue.allPending;
    for (final env in pending) {
      try {
        transport.sendBytes(endpointId: endpointId, bytes: env.toBytes());
        storeAndForwardQueue.remove(env.envelopeId);
      } catch (_) {}
    }
  }

  void _flushQueueForNode(String nodeId, String endpointId) {
    final pendingForNode = storeAndForwardQueue.getPendingForTarget(nodeId);
    for (final env in pendingForNode) {
      try {
        transport.sendBytes(endpointId: endpointId, bytes: env.toBytes());
        storeAndForwardQueue.remove(env.envelopeId);
      } catch (_) {}
    }
  }

  void dispose() {
    _eventsSub?.cancel();
    _payloadSub?.cancel();
    _incomingMessagesController.close();
    _forwardedMessagesController.close();
  }
}
