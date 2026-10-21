import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../features/chat/data/repositories/chat_repository.dart';
import '../../features/chat/models/chat_message.dart';
import '../transport/mesh_transport.dart';
import '../ids/ids_types.dart';
import '../ids/selective_forwarding_detector.dart';
import '../trust/dynamic_trust_manager.dart';
import '../blockchain/blockdag_security_coordinator.dart';
import '../blockchain/gossip/gossip.dart';
import 'deduplication_cache.dart';
import 'mesh_experiment_logger.dart';
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
  final MeshExperimentLogger? experimentLogger;
  final SelectiveForwardingDetector? idsDetector;
  final DynamicTrustManager? trustManager;
  final BlockdagSecurityCoordinator? blockdagCoordinator;
  final bool enableHopAck;
  final bool enableTrustRoutingPolicy;
  final bool autoStartIdsTimeoutTimer;
  DagGossipSyncEngine? gossipSyncEngine;

  StreamSubscription<TransportConnectionEvent>? _eventsSub;
  StreamSubscription<TransportPayload>? _payloadSub;
  StreamSubscription<IdsDetectionEvent>? _idsToTrustSub;

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
    this.experimentLogger,
    this.idsDetector,
    this.trustManager,
    this.blockdagCoordinator,
    this.enableHopAck = false,
    this.enableTrustRoutingPolicy = false,
    this.autoStartIdsTimeoutTimer = false,
    this.gossipSyncEngine,
  }) : neighborTable = neighborTable ?? NeighborTable(),
       dedupCache = dedupCache ?? DeduplicationCache(),
       storeAndForwardQueue = storeAndForwardQueue ?? StoreAndForwardQueue() {
    if (idsDetector != null && experimentLogger != null) {
      idsDetector!.experimentLogger ??= experimentLogger;
    }
    if (trustManager != null && experimentLogger != null) {
      trustManager!.experimentLogger ??= experimentLogger;
    }
    if (idsDetector != null && trustManager != null) {
      _idsToTrustSub = idsDetector!.detectionEventsStream.listen((event) {
        trustManager!.observeIdsEvent(event);
      });
    }
    if (idsDetector != null && autoStartIdsTimeoutTimer) {
      idsDetector!.startPeriodicTimeoutCheck(
        interval: const Duration(milliseconds: 1000),
        isPeerConnected: (peerId) =>
            this.neighborTable.activeNeighbors.any((p) => p.nodeId == peerId),
      );
    }
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
      final peer = neighborTable.getPeerByEndpoint(event.endpointId);
      final peerNodeId = peer?.nodeId;
      neighborTable.markDisconnected(event.endpointId);
      if (peerNodeId != null && !peerNodeId.startsWith('pending-')) {
        // Hanya daftarkan link failure jika node tidak lagi memiliki endpoint aktif lain
        if (!neighborTable.isNodeConnected(peerNodeId)) {
          idsDetector?.registerLinkFailure(
            peerNodeId: peerNodeId,
            reason: 'TRANSPORT_LINK_DISCONNECTED',
          );
        }
      }
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

  /// Mengumumkan kehadiran dan identitas (handshake) terbaru ke seluruh tetangga aktif.
  Future<void> announcePresence() async {
    final active = neighborTable.activeNeighbors;
    for (final neighbor in active) {
      await _sendHandshake(neighbor.endpointId);
    }
  }

  // --- Penanganan Payload Nirkabel Masuk ---

  void _handleIncomingPayload(TransportPayload payload) async {
    final bytes = payload.bytes;
    if (bytes.isEmpty) return;

    // Decoding JSON sekali saja untuk seluruh alur routing dan gossip
    dynamic decodedJson;
    try {
      final jsonStr = utf8.decode(bytes);
      decodedJson = jsonDecode(jsonStr);
    } catch (_) {
      // Bukan encoding UTF-8 atau JSON valid
    }

    if (decodedJson is Map<String, dynamic>) {
      // 0. Dispatch payload protokol gossip BlockDAG (DAG-Sync) tanpa mem-parse sebagai chat envelope
      if (DagGossipSyncEngine.claimsGossipProtocol(decodedJson)) {
        if (gossipSyncEngine != null && gossipSyncEngine!.isEnabled) {
          try {
            await gossipSyncEngine!.handleIncomingPayloadMap(
              endpointId: payload.endpointId,
              map: decodedJson,
              rawByteLength: bytes.length,
            );
          } catch (e) {
            debugPrint(
              '[RoutingEngine] Kesalahan pada penanganan payload gossip: $e',
            );
          }
        }
        // Hentikan pemrosesan agar tidak di-parse sebagai chat MessageEnvelope atau masuk ChatRepository
        return;
      }

      // 1. Coba parse sebagai MessageEnvelope obrolan/routing
      final envelope = MessageEnvelope.fromMap(decodedJson);
      if (envelope != null) {
        await _processIncomingEnvelope(envelope, payload);
        return;
      }
    }

    // 2. Tolak data korup, tidak lengkap, atau versi tidak didukung secara aman
    experimentLogger?.log(
      envelopeId: 'corrupted',
      messageId: 'corrupted',
      senderId: 'unknown',
      recipientId: localNodeId,
      eventType: MeshExperimentEventType.rejected,
      hopCount: 0,
      routeTrace: const [],
      connectionStatus: 'CONNECTED',
      activeNeighborCount: neighborTable.activeNeighbors.length,
      failureReason: 'CORRUPT_OR_UNSUPPORTED_PAYLOAD',
      outcome: 'DROPPED',
    );
  }

  void _logDiag({
    required String stage,
    required String msgId,
    required String type,
    required String sender,
    required String dest,
    String? endpoint,
    String? outcome,
    String? reason,
  }) {
    debugPrint(
      '[SiagaMesh-Diag] Stage=$stage | msgId=$msgId | type=$type | sender=$sender | dest=$dest | localNode=$localNodeId'
      '${endpoint != null ? ' | ep=$endpoint' : ''}'
      '${outcome != null ? ' | outcome=$outcome' : ''}'
      '${reason != null ? ' | reason=$reason' : ''}',
    );
  }

  Future<void> _processIncomingEnvelope(
    MessageEnvelope envelope,
    TransportPayload payload,
  ) async {
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

      _logDiag(
        stage: 'HANDSHAKE_MAPPED',
        msgId: envelope.envelopeId,
        type: 'HANDSHAKE',
        sender: remoteNodeId,
        dest: localNodeId,
        endpoint: payload.endpointId,
        outcome: 'IDENTITY_MAPPED',
      );

      // Sinkronkan ke ChatRepository lokal jika percakapan sudah ada atau terdapat percakapan sementara yang perlu dimigrasikan
      if (repository != null) {
        try {
          final existing = await repository!.getConversations();
          final cleanRemoteId = remoteNodeId
              .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
              .trim()
              .toLowerCase();
          final hasExistingOrTemp = existing.any((c) {
            final pId = (c.peerNodeId ?? '').toLowerCase();
            return pId == cleanRemoteId ||
                pId == 'peer-${payload.endpointId.toLowerCase()}' ||
                pId == 'pending-${payload.endpointId.toLowerCase()}' ||
                c.id.toLowerCase() == 'conv-node-$cleanRemoteId';
          });
          if (hasExistingOrTemp) {
            if (repository is LocalChatRepository) {
              await (repository as LocalChatRepository)
                  .getOrCreateConversationForNode(
                    nodeId: remoteNodeId,
                    nodeName: remoteNodeName,
                    isConnected: true,
                    endpointId: payload.endpointId,
                  );
            } else {
              await repository!.getOrCreateConversationForNode(
                nodeId: remoteNodeId,
                nodeName: remoteNodeName,
                isConnected: true,
              );
            }
          }
        } catch (_) {}
      }

      // Setelah identitas node terpetakan, coba flush antrean store-and-forward
      _flushQueueForNode(remoteNodeId, payload.endpointId);
      return;
    }

    // 2. Tangani Tanda Terima Hop Relai (HOP_ACK / RELAY_CLAIM)
    if (envelope.type == MessageEnvelope.typeHopAck) {
      final ackedEnvelopeId = envelope.payload['ackedEnvelopeId'] as String?;
      if (ackedEnvelopeId != null) {
        final registered =
            idsDetector?.registerRelayClaimed(
              peerNodeId: envelope.senderId,
              envelopeId: ackedEnvelopeId,
            ) ??
            false;

        _logDiag(
          stage: 'RECEIVED_HOP_ACK',
          msgId: ackedEnvelopeId,
          type: 'HOP_ACK',
          sender: envelope.senderId,
          dest: localNodeId,
          endpoint: payload.endpointId,
          outcome: registered ? 'HOP_ACK_MATCHED' : 'HOP_ACK_UNMATCHED',
        );

        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: ackedEnvelopeId,
          senderId: envelope.senderId,
          recipientId: localNodeId,
          eventType: MeshExperimentEventType.received,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: registered ? 'HOP_ACK_RELAY_CLAIMED' : 'HOP_ACK_UNMATCHED',
          syntheticMetadata: {
            'ackedEnvelopeId': ackedEnvelopeId,
            'evidenceLevel': 'RELAY_CLAIMED',
            'isVerifiedDownstream': false,
            'isObligationMatched': registered,
          },
        );
      }
      return;
    }

    // 2b. Tangani Konfirmasi Pengiriman Akhir (E2E_ACK)
    if (envelope.type == MessageEnvelope.typeE2eAck) {
      final isForMe =
          envelope.recipientId.trim().toLowerCase() ==
          localNodeId.trim().toLowerCase();
      final ackedEnvelopeId = envelope.payload['ackedEnvelopeId'] as String?;
      final ackedMessageId = envelope.payload['ackedMessageId'] as String?;

      if (isForMe) {
        _logDiag(
          stage: 'CONFIRMED_E2E_ACK',
          msgId: ackedMessageId ?? ackedEnvelopeId ?? envelope.envelopeId,
          type: 'E2E_ACK',
          sender: envelope.senderId,
          dest: localNodeId,
          endpoint: payload.endpointId,
          outcome: 'DELIVERY_CONFIRMED_BY_DESTINATION',
        );

        // Catat bukti penerimaan akhir terkonfirmasi ke DynamicTrustManager
        trustManager?.observeDirectEvidence(
          targetNodeId: envelope.senderId,
          evidenceType: ForwardingEvidenceType.deliveryConfirmed,
          evidenceId: envelope.envelopeId,
        );

        // Emisi event agar UI obrolan dapat memperbarui status centang / penerimaan
        _incomingMessagesController.add(envelope);

        // Perbarui status penyimpanan di repository jika tersedia
        if (repository != null && ackedMessageId != null) {
          final convId = 'conv-node-${envelope.senderId}';
          try {
            await repository!.updateMessageStatus(
              convId,
              ackedMessageId,
              'Diterima di Perangkat Tujuan (E2E ACK)',
            );
          } catch (_) {}
        }
        return;
      } else if (envelope.ttl > 1) {
        _logDiag(
          stage: 'RELAY_E2E_ACK',
          msgId: ackedMessageId ?? envelope.envelopeId,
          type: 'E2E_ACK',
          sender: envelope.senderId,
          dest: envelope.recipientId,
          outcome: 'FORWARDING_ACK',
        );
        await _forwardToOtherNeighbors(
          envelope: envelope,
          sourceEndpointId: payload.endpointId,
        );
        return;
      }
    }

    // 3. Tangani Pesan Obrolan (CHAT_MESSAGE)
    if (envelope.type == MessageEnvelope.typeChat) {
      final messageId =
          envelope.payload['messageId'] as String? ?? envelope.envelopeId;

      // Aturan A: Pemeriksaan Deduplikasi
      if (dedupCache.checkAndAdd(envelope.envelopeId)) {
        // Pesan duplikat telah dilihat sebelumnya, hentikan penyebaran!
        idsDetector?.registerProtocolDrop(
          peerNodeId: envelope.senderId,
          envelopeId: envelope.envelopeId,
          reason: 'DEDUP_CACHE_HIT',
        );
        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: messageId,
          senderId: envelope.senderId,
          recipientId: envelope.recipientId,
          eventType: MeshExperimentEventType.rejected,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          failureReason: 'DEDUP_CACHE_HIT',
          outcome: 'DROPPED_DUPLICATE',
        );
        return;
      }

      // Aturan B: Pencegahan Loop Perutean
      if (envelope.routeTrace.contains(localNodeId)) {
        // Pesan sudah pernah melewati node ini sebelumnya, hentikan loop!
        idsDetector?.registerProtocolDrop(
          peerNodeId: envelope.senderId,
          envelopeId: envelope.envelopeId,
          reason: 'ROUTE_LOOP_DETECTED',
        );
        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: messageId,
          senderId: envelope.senderId,
          recipientId: envelope.recipientId,
          eventType: MeshExperimentEventType.rejected,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          failureReason: 'ROUTE_LOOP_DETECTED',
          outcome: 'DROPPED_LOOP',
        );
        return;
      }

      // Aturan C: Pemeriksaan Batas Hop / TTL
      if (envelope.ttl <= 0) {
        // Masa hidup paket habis, buang!
        idsDetector?.registerProtocolDrop(
          peerNodeId: envelope.senderId,
          envelopeId: envelope.envelopeId,
          reason: 'TTL_EXPIRED',
        );
        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: messageId,
          senderId: envelope.senderId,
          recipientId: envelope.recipientId,
          eventType: MeshExperimentEventType.expired,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          failureReason: 'TTL_EXPIRED',
          outcome: 'DROPPED_EXPIRED',
        );
        return;
      }

      // Aturan D: Penentuan Tujuan
      final isBroadcast =
          envelope.recipientId.trim().toUpperCase() == 'BROADCAST';
      final isForMe =
          !isBroadcast &&
          (envelope.recipientId.trim().toLowerCase() ==
                  localNodeId.trim().toLowerCase() ||
              envelope.recipientId.trim().toLowerCase() ==
                  payload.endpointId.toLowerCase() ||
              neighborTable
                      .getNodeIdForEndpoint(payload.endpointId)
                      ?.toLowerCase() ==
                  envelope.recipientId.trim().toLowerCase());

      if (isForMe || isBroadcast) {
        // Node ini adalah penerima tujuan akhir
        await _deliverToLocalApp(envelope, isBroadcast: isBroadcast);
        _incomingMessagesController.add(envelope);

        _logDiag(
          stage: 'DELIVERED_TO_APP',
          msgId: messageId,
          type: isBroadcast ? 'BROADCAST' : 'PERSONAL',
          sender: envelope.senderId,
          dest: envelope.recipientId,
          endpoint: payload.endpointId,
          outcome: 'DELIVERED_TO_APP',
        );

        // Jika pesan personal (1-to-1), kirim konfirmasi penerimaan akhir (E2E_ACK)
        if (!isBroadcast) {
          _sendE2eAck(
            targetNodeId: envelope.senderId,
            ackedEnvelopeId: envelope.envelopeId,
            ackedMessageId: messageId,
            directEndpointId: payload.endpointId,
          );
        }

        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: messageId,
          senderId: envelope.senderId,
          recipientId: envelope.recipientId,
          eventType: MeshExperimentEventType.received,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: 'DELIVERED_TO_APP',
          syntheticMetadata: {
            'isBroadcast': isBroadcast,
            'isEmergency': envelope.payload['isEmergency'] == true,
          },
        );

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
        _logDiag(
          stage: 'RELAY_TRANSIT',
          msgId: messageId,
          type: 'PERSONAL',
          sender: envelope.senderId,
          dest: envelope.recipientId,
          endpoint: payload.endpointId,
          outcome: 'RELAY_TRANSIT',
        );

        experimentLogger?.log(
          envelopeId: envelope.envelopeId,
          messageId: messageId,
          senderId: envelope.senderId,
          recipientId: envelope.recipientId,
          eventType: MeshExperimentEventType.received,
          hopCount: envelope.hopCount,
          routeTrace: envelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: 'RELAY_TRANSIT',
        );

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
    final messageId =
        forwardedEnvelope.payload['messageId'] as String? ??
        forwardedEnvelope.envelopeId;

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
        experimentLogger?.log(
          envelopeId: forwardedEnvelope.envelopeId,
          messageId: messageId,
          senderId: forwardedEnvelope.senderId,
          recipientId: forwardedEnvelope.recipientId,
          eventType: MeshExperimentEventType.forwarded,
          hopCount: forwardedEnvelope.hopCount,
          routeTrace: forwardedEnvelope.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: activeNeighbors.length,
          outcome: 'FORWARDED_DIRECT_NEIGHBOR',
        );

        // Kirim HOP_ACK ke pengirim sebelumnya jika diaktifkan
        if (enableHopAck || (idsDetector?.config.autoSendHopAck ?? false)) {
          _sendHopAck(sourceEndpointId, envelope.envelopeId);
        }

        // Daftarkan ekspektasi ke hop berikutnya jika bukan tujuan akhir dan TTL > 1
        final nextHopNodeId = neighborTable.getNodeIdForEndpoint(
          directEndpointId,
        );
        if (nextHopNodeId != null &&
            nextHopNodeId != forwardedEnvelope.recipientId &&
            forwardedEnvelope.ttl > 1) {
          idsDetector?.registerForwardingExpected(
            peerNodeId: nextHopNodeId,
            envelopeId: forwardedEnvelope.envelopeId,
          );
        }
        return;
      } catch (e) {
        debugPrint(
          '[RoutingEngine] Gagal forward langsung ke $directEndpointId: $e',
        );
      }
    }

    // Controlled Flooding: Kirim ke semua tetangga aktif selain pengirim asal
    // dan selain node yang sudah tercatat di route trace
    var candidateNeighbors = activeNeighbors.where((neighbor) {
      if (neighbor.endpointId == sourceEndpointId) return false;
      if (forwardedEnvelope.routeTrace.contains(neighbor.nodeId)) return false;
      return true;
    }).toList();

    // Saring kandidat perantara berdasarkan kebijakan Dynamic Trust jika diaktifkan (Konfigurasi B)
    if (enableTrustRoutingPolicy && trustManager != null) {
      candidateNeighbors = trustManager!.filterForwardingPeers<NeighborPeer>(
        peers: candidateNeighbors,
        getNodeId: (n) => n.nodeId,
        destinationId: forwardedEnvelope.recipientId,
        onDecision: (peerId, decision, score) {
          experimentLogger?.log(
            envelopeId: forwardedEnvelope.envelopeId,
            messageId: messageId,
            senderId: localNodeId,
            recipientId: peerId,
            eventType: MeshExperimentEventType.forwarded,
            hopCount: forwardedEnvelope.hopCount,
            routeTrace: forwardedEnvelope.routeTrace,
            connectionStatus: 'ACTIVE',
            activeNeighborCount: activeNeighbors.length,
            outcome: decision,
            syntheticMetadata: {'trustScore': score, 'decision': decision},
          );
          if (decision == 'BLOCKED_UNTRUSTED_RELAY' &&
              blockdagCoordinator != null) {
            blockdagCoordinator!.recordIsolationDecision(
              eventId: 'iso-$peerId-${forwardedEnvelope.envelopeId}',
              targetNodeId: peerId,
              action: 'isolate',
              score: score,
              reason:
                  'Untrusted relay blocked from forwarding envelope ${forwardedEnvelope.envelopeId}',
            );
          }
        },
      );
    }

    bool anySent = false;
    for (final neighbor in candidateNeighbors) {
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
      experimentLogger?.log(
        envelopeId: forwardedEnvelope.envelopeId,
        messageId: messageId,
        senderId: forwardedEnvelope.senderId,
        recipientId: forwardedEnvelope.recipientId,
        eventType: MeshExperimentEventType.forwarded,
        hopCount: forwardedEnvelope.hopCount,
        routeTrace: forwardedEnvelope.routeTrace,
        connectionStatus: 'CONNECTED',
        activeNeighborCount: activeNeighbors.length,
        outcome: 'FORWARDED_FLOODING',
      );

      // Kirim HOP_ACK ke pengirim sebelumnya jika diaktifkan
      if (enableHopAck || (idsDetector?.config.autoSendHopAck ?? false)) {
        _sendHopAck(sourceEndpointId, envelope.envelopeId);
      }

      // Daftarkan ekspektasi ke seluruh tetangga downstream jika TTL > 1
      if (idsDetector != null && forwardedEnvelope.ttl > 1) {
        for (final neighbor in candidateNeighbors) {
          if (neighbor.endpointId != sourceEndpointId &&
              neighbor.nodeId != forwardedEnvelope.recipientId &&
              !forwardedEnvelope.routeTrace.contains(neighbor.nodeId)) {
            idsDetector?.registerForwardingExpected(
              peerNodeId: neighbor.nodeId,
              envelopeId: forwardedEnvelope.envelopeId,
            );
          }
        }
      }
    } else {
      // Jika tidak ada tetangga lain yang dapat dijangkau, simpan di buffer antrean
      storeAndForwardQueue.enqueue(forwardedEnvelope);
      experimentLogger?.log(
        envelopeId: forwardedEnvelope.envelopeId,
        messageId: messageId,
        senderId: forwardedEnvelope.senderId,
        recipientId: forwardedEnvelope.recipientId,
        eventType: MeshExperimentEventType.queued,
        hopCount: forwardedEnvelope.hopCount,
        routeTrace: forwardedEnvelope.routeTrace,
        connectionStatus: activeNeighbors.isEmpty ? 'DISCONNECTED' : 'PARTIAL',
        activeNeighborCount: activeNeighbors.length,
        failureReason: 'NO_ELIGIBLE_NEXT_HOP',
        outcome: 'STORED_IN_BUFFER',
      );
    }
  }

  void _sendHopAck(String targetEndpointId, String ackedEnvelopeId) async {
    final targetNodeId =
        neighborTable.getNodeIdForEndpoint(targetEndpointId) ?? 'BROADCAST';
    final hopAck = MessageEnvelope(
      envelopeId: 'ack-$ackedEnvelopeId-$localNodeId',
      type: MessageEnvelope.typeHopAck,
      senderId: localNodeId,
      senderName: localNodeName,
      recipientId: targetNodeId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      ttl: 1,
      hopCount: 0,
      routeTrace: [localNodeId],
      payload: {'ackedEnvelopeId': ackedEnvelopeId, 'status': 'RELAY_CLAIMED'},
    );
    try {
      await transport.sendBytes(
        endpointId: targetEndpointId,
        bytes: hopAck.toBytes(),
      );
    } catch (_) {}
  }

  /// Mengirimkan konfirmasi penerimaan akhir (End-to-End Delivery ACK) langsung
  /// dari node tujuan menuju node pengirim awal pesan.
  void _sendE2eAck({
    required String targetNodeId,
    required String ackedEnvelopeId,
    required String ackedMessageId,
    String? directEndpointId,
  }) async {
    final e2eAck = MessageEnvelope(
      envelopeId: 'e2e-ack-$ackedEnvelopeId-$localNodeId',
      type: MessageEnvelope.typeE2eAck,
      senderId: localNodeId,
      senderName: localNodeName,
      recipientId: targetNodeId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      ttl: MessageEnvelope.defaultTtl,
      hopCount: 0,
      routeTrace: [localNodeId],
      payload: {
        'ackedEnvelopeId': ackedEnvelopeId,
        'ackedMessageId': ackedMessageId,
        'status': 'DELIVERED_TO_DESTINATION',
      },
    );

    _logDiag(
      stage: 'SEND_E2E_ACK',
      msgId: ackedMessageId,
      type: 'E2E_ACK',
      sender: localNodeId,
      dest: targetNodeId,
      endpoint: directEndpointId,
      outcome: 'E2E_ACK_SENT',
    );

    final epId =
        directEndpointId ?? neighborTable.getEndpointIdForNode(targetNodeId);
    if (epId != null) {
      try {
        await transport.sendBytes(endpointId: epId, bytes: e2eAck.toBytes());
      } catch (_) {}
    } else {
      for (final neighbor in neighborTable.activeNeighbors) {
        try {
          await transport.sendBytes(
            endpointId: neighbor.endpointId,
            bytes: e2eAck.toBytes(),
          );
        } catch (_) {}
      }
    }
  }

  /// Menyampaikan pesan yang ditujukan untuk node ini ke ChatRepository lokal.
  Future<void> _deliverToLocalApp(
    MessageEnvelope envelope, {
    required bool isBroadcast,
  }) async {
    final repo = repository ?? ChatRepositoryHolder.instance;

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
      await repo.saveMessage('broadcast-all', chatMessage);
      _logDiag(
        stage: 'DELIVERED_TO_APP_REPO',
        msgId: messageId,
        type: 'BROADCAST',
        sender: envelope.senderId,
        dest: 'BROADCAST',
        outcome: 'SAVED_TO_BROADCAST_CONV',
      );
    } else {
      final conv = await repo.getOrCreateConversationForNode(
        nodeId: envelope.senderId,
        nodeName: envelope.senderName,
        isEmergency: isEmergency,
        isConnected: true,
      );
      await repo.saveMessage(conv.id, chatMessage);
      _logDiag(
        stage: 'DELIVERED_TO_APP_REPO',
        msgId: messageId,
        type: 'PERSONAL',
        sender: envelope.senderId,
        dest: localNodeId,
        outcome: 'SAVED_TO_PERSONAL_CONV',
      );
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

    // Normalisasi & resolusi recipientNodeId yang aman dan akurat
    String cleanRecipient = recipientNodeId
        .replaceFirst(RegExp(r'^Node:\s*#?', caseSensitive: false), '')
        .trim();

    // Resolusi jika cleanRecipient berawalan 'peer-' atau merupakan endpoint ID
    if (cleanRecipient.startsWith('peer-')) {
      final subEp = cleanRecipient.substring(5);
      final mapped = neighborTable.getNodeIdForEndpoint(subEp);
      if (mapped != null && !mapped.startsWith('pending-')) {
        cleanRecipient = mapped;
      }
    } else if (neighborTable.getNodeIdForEndpoint(cleanRecipient) != null) {
      final mapped = neighborTable.getNodeIdForEndpoint(cleanRecipient);
      if (mapped != null && !mapped.startsWith('pending-')) {
        cleanRecipient = mapped;
      }
    }

    final isBroadcast = cleanRecipient.toUpperCase() == 'BROADCAST';
    final canonicalRecipientId = isBroadcast ? 'BROADCAST' : cleanRecipient;

    final envelope = MessageEnvelope(
      envelopeId: envelopeId,
      type: MessageEnvelope.typeChat,
      senderId: localNodeId,
      senderName: localNodeName,
      recipientId: canonicalRecipientId,
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

    _logDiag(
      stage: 'CREATED',
      msgId: messageId,
      type: isBroadcast ? 'BROADCAST' : 'PERSONAL',
      sender: localNodeId,
      dest: canonicalRecipientId,
      outcome: 'CREATED_LOCALLY',
    );

    experimentLogger?.log(
      envelopeId: envelopeId,
      messageId: messageId,
      senderId: localNodeId,
      recipientId: canonicalRecipientId,
      eventType: MeshExperimentEventType.created,
      hopCount: 0,
      routeTrace: [localNodeId],
      connectionStatus: neighborTable.activeNeighbors.isNotEmpty
          ? 'CONNECTED'
          : 'DISCONNECTED',
      activeNeighborCount: neighborTable.activeNeighbors.length,
      outcome: 'CREATED_LOCALLY',
      syntheticMetadata: {
        'isEmergency': isEmergency,
        'hasTelemetry': telemetry != null,
      },
    );

    // Kirim ke transport
    final bytes = envelope.toBytes();
    final activeNeighbors = neighborTable.activeNeighbors;

    bool sentAnywhere = false;

    // Jika tujuan langsung terhubung (1-hop langsung)
    final directEndpointId = isBroadcast
        ? null
        : (neighborTable.getEndpointIdForNode(canonicalRecipientId) ??
              neighborTable.getEndpointIdForNode(cleanRecipient));

    if (directEndpointId != null) {
      try {
        final ok = await transport.sendBytes(
          endpointId: directEndpointId,
          bytes: bytes,
        );
        if (ok) {
          sentAnywhere = true;
          _logDiag(
            stage: 'SENT_TO_TRANSPORT',
            msgId: messageId,
            type: 'PERSONAL',
            sender: localNodeId,
            dest: canonicalRecipientId,
            endpoint: directEndpointId,
            outcome: 'TRANSMITTED_DIRECT',
          );
          experimentLogger?.log(
            envelopeId: envelopeId,
            messageId: messageId,
            senderId: localNodeId,
            recipientId: canonicalRecipientId,
            eventType: MeshExperimentEventType.sentToTransport,
            hopCount: 0,
            routeTrace: [localNodeId],
            connectionStatus: 'CONNECTED',
            activeNeighborCount: activeNeighbors.length,
            outcome: 'TRANSMITTED_DIRECT',
          );
        }
      } catch (_) {}
    } else if (activeNeighbors.isNotEmpty) {
      var targetNeighbors = activeNeighbors;
      if (enableTrustRoutingPolicy && trustManager != null) {
        targetNeighbors = trustManager!.filterForwardingPeers<NeighborPeer>(
          peers: activeNeighbors,
          getNodeId: (n) => n.nodeId,
          destinationId: canonicalRecipientId,
          onDecision: (peerId, decision, score) {
            experimentLogger?.log(
              envelopeId: envelopeId,
              messageId: messageId,
              senderId: localNodeId,
              recipientId: peerId,
              eventType: MeshExperimentEventType.sentToTransport,
              hopCount: 0,
              routeTrace: [localNodeId],
              connectionStatus: 'ACTIVE',
              activeNeighborCount: activeNeighbors.length,
              outcome: decision,
              syntheticMetadata: {'trustScore': score, 'decision': decision},
            );
            if (decision == 'BLOCKED_UNTRUSTED_RELAY' &&
                blockdagCoordinator != null) {
              blockdagCoordinator!.recordIsolationDecision(
                eventId: 'iso-$peerId-$envelopeId',
                targetNodeId: peerId,
                action: 'isolate',
                score: score,
                reason: 'Untrusted relay blocked from initial broadcast/relay',
              );
            }
          },
        );
      }

      // Flooding/Forwarding ke tetangga yang memenuhi syarat kebijakan
      for (final neighbor in targetNeighbors) {
        try {
          final ok = await transport.sendBytes(
            endpointId: neighbor.endpointId,
            bytes: bytes,
          );
          if (ok) sentAnywhere = true;
        } catch (_) {}
      }
      if (sentAnywhere) {
        _logDiag(
          stage: 'SENT_TO_TRANSPORT',
          msgId: messageId,
          type: isBroadcast ? 'BROADCAST' : 'PERSONAL',
          sender: localNodeId,
          dest: canonicalRecipientId,
          outcome: 'TRANSMITTED_FLOODING',
        );
        experimentLogger?.log(
          envelopeId: envelopeId,
          messageId: messageId,
          senderId: localNodeId,
          recipientId: canonicalRecipientId,
          eventType: MeshExperimentEventType.sentToTransport,
          hopCount: 0,
          routeTrace: [localNodeId],
          connectionStatus: 'CONNECTED',
          activeNeighborCount: targetNeighbors.length,
          outcome: 'TRANSMITTED_FLOODING',
        );

        if (idsDetector != null && envelope.ttl > 1) {
          for (final neighbor in targetNeighbors) {
            if (neighbor.nodeId != canonicalRecipientId) {
              idsDetector?.registerForwardingExpected(
                peerNodeId: neighbor.nodeId,
                envelopeId: envelope.envelopeId,
              );
            }
          }
        }
      }
    }

    if (!sentAnywhere) {
      // Tidak ada tetangga aktif yang menerima, simpan ke antrean store-and-forward
      storeAndForwardQueue.enqueue(envelope);
      _logDiag(
        stage: 'QUEUED',
        msgId: messageId,
        type: isBroadcast ? 'BROADCAST' : 'PERSONAL',
        sender: localNodeId,
        dest: canonicalRecipientId,
        outcome: 'STORED_IN_BUFFER',
        reason: activeNeighbors.isEmpty
            ? 'NO_ACTIVE_NEIGHBOR'
            : 'ALL_SENDS_FAILED',
      );
      experimentLogger?.log(
        envelopeId: envelopeId,
        messageId: messageId,
        senderId: localNodeId,
        recipientId: canonicalRecipientId,
        eventType: MeshExperimentEventType.queued,
        hopCount: 0,
        routeTrace: [localNodeId],
        connectionStatus: activeNeighbors.isEmpty
            ? 'DISCONNECTED'
            : 'SEND_FAILED',
        activeNeighborCount: activeNeighbors.length,
        failureReason: activeNeighbors.isEmpty
            ? 'NO_ACTIVE_NEIGHBOR'
            : 'ALL_SENDS_FAILED',
        outcome: 'STORED_IN_BUFFER',
      );
    }

    return envelope;
  }

  void _flushQueueForEndpoint(String endpointId) {
    final pending = storeAndForwardQueue.allPending;
    for (final env in pending) {
      try {
        transport.sendBytes(endpointId: endpointId, bytes: env.toBytes());
        storeAndForwardQueue.remove(env.envelopeId);
        experimentLogger?.log(
          envelopeId: env.envelopeId,
          messageId: env.payload['messageId'] as String? ?? env.envelopeId,
          senderId: env.senderId,
          recipientId: env.recipientId,
          eventType: MeshExperimentEventType.sentToTransport,
          hopCount: env.hopCount,
          routeTrace: env.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: 'QUEUE_FLUSHED_FOR_ENDPOINT',
        );
      } catch (_) {}
    }
  }

  void _flushQueueForNode(String nodeId, String endpointId) {
    final pendingForNode = storeAndForwardQueue.getPendingForTarget(nodeId);
    for (final env in pendingForNode) {
      try {
        transport.sendBytes(endpointId: endpointId, bytes: env.toBytes());
        storeAndForwardQueue.remove(env.envelopeId);
        experimentLogger?.log(
          envelopeId: env.envelopeId,
          messageId: env.payload['messageId'] as String? ?? env.envelopeId,
          senderId: env.senderId,
          recipientId: env.recipientId,
          eventType: MeshExperimentEventType.sentToTransport,
          hopCount: env.hopCount,
          routeTrace: env.routeTrace,
          connectionStatus: 'CONNECTED',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: 'QUEUE_FLUSHED_FOR_NODE',
        );
      } catch (_) {}
    }
  }

  /// Membatalkan pesan dari antrean store-and-forward berdasarkan messageId atau envelopeId.
  bool cancelQueuedMessage(String messageId) {
    final pending = storeAndForwardQueue.allPending;
    for (final env in pending) {
      final envMsgId = env.payload['messageId'] as String? ?? env.envelopeId;
      if (envMsgId == messageId || env.envelopeId == messageId) {
        storeAndForwardQueue.remove(env.envelopeId);
        experimentLogger?.log(
          envelopeId: env.envelopeId,
          messageId: envMsgId,
          senderId: env.senderId,
          recipientId: env.recipientId,
          eventType: MeshExperimentEventType.queued,
          hopCount: env.hopCount,
          routeTrace: env.routeTrace,
          connectionStatus: 'LOCAL',
          activeNeighborCount: neighborTable.activeNeighbors.length,
          outcome: 'CANCELLED_FROM_QUEUE',
        );
        debugPrint(
          '[RoutingEngine] Pesan antrean $messageId dibatalkan dari store-and-forward',
        );
        return true;
      }
    }
    return false;
  }

  /// Memeriksa apakah pesan dengan messageId atau envelopeId ada di antrean transmisi.
  bool isMessageQueued(String messageId) {
    return storeAndForwardQueue.containsMessageId(messageId);
  }

  void dispose() {
    _eventsSub?.cancel();
    _payloadSub?.cancel();
    _idsToTrustSub?.cancel();
    _idsToTrustSub = null;
    idsDetector?.stopPeriodicTimeoutCheck();
    _incomingMessagesController.close();
    _forwardedMessagesController.close();
    gossipSyncEngine?.dispose();
  }
}
