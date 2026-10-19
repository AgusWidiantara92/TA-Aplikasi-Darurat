/// STAGE 5E.3 — Pengujian Integrasi Security Event dan Penyimpanan Lokal BlockDAG SiagaMesh
///
/// Memverifikasi 18 skenario integrasi:
/// 1. Event IDS menjadi security audit event
/// 2. TrustScoreChangeEvent menjadi security audit event
/// 3. Isi chat tidak terdapat pada serialized event dan blok
/// 4. Event ID yang sama tidak dicatat dua kali (deduplikasi)
/// 5. Event malformed ditolak
/// 6. Batch dibuat tepat satu kali saat mencapai jumlah maksimum
/// 7. Timer flushing berfungsi menggunakan waktu uji yang dapat dikendalikan
/// 8. Batas batch dan timer yang terjadi bersamaan tidak menciptakan blok duplikat
/// 9. Kegagalan penulisan ledger tidak menghentikan routing
/// 10. Ledger dapat dipulihkan setelah repository dibuat ulang
/// 11. Data tersimpan rusak ditangani secara eksplisit dan aman
/// 12. Event yang belum tersimpan tidak hilang tanpa pencatatan kegagalan
/// 13. Retensi dan checkpoint tetap konsisten setelah restore
/// 14. Deduplikasi tetap bekerja setelah restart sesuai cakupan retensi
/// 15. Konfigurasi A tidak bergantung pada ledger
/// 16. Konfigurasi B dapat berjalan tanpa ledger
/// 17. Konfigurasi C mencatat event IDS dan trust
/// 18. Instrumentasi metrik dan verifikasi non-interferensi
library;

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:siagamesh_app/core/blockchain/blockchain_types.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_repository.dart';
import 'package:siagamesh_app/core/blockchain/blockdag_security_coordinator.dart';
import 'package:siagamesh_app/core/blockchain/lightweight_blockdag_ledger.dart';
import 'package:siagamesh_app/core/ids/ids_types.dart';
import 'package:siagamesh_app/core/ids/selective_forwarding_detector.dart';
import 'package:siagamesh_app/core/routing/manet_routing_engine.dart';
import 'package:siagamesh_app/core/routing/node_identity.dart';
import 'package:siagamesh_app/core/routing/routing_holder.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/core/trust/dynamic_trust_manager.dart';
import 'package:siagamesh_app/core/trust/trust_types.dart';
import 'package:siagamesh_app/features/chat/data/repositories/chat_repository.dart';

/// Fake repository yang sengaja gagal menulis untuk menguji toleransi kesalahan.
class FailingBlockdagRepository implements BlockdagRepository {
  int saveAttempts = 0;
  BlockdagLoadResult loadResultStub = BlockdagLoadResult.empty();

  @override
  Future<BlockdagLoadResult> loadResult() async => loadResultStub;

  @override
  Future<BlockdagPersistedState?> loadState() async => loadResultStub.state;

  @override
  Future<bool> saveState(BlockdagPersistedState state) async {
    saveAttempts++;
    return false; // Selalu gagal menulis
  }

  @override
  Future<bool> clear() async => true;

  @override
  bool get lastLoadCorrupted => loadResultStub.isCorrupted;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ManetRoutingHolder.reset();
  });

  group('STAGE 5E.3 — Integrasi Security Event dan Penyimpanan Lokal BlockDAG', () {
    // -------------------------------------------------------------------------
    // 1. Event IDS menjadi security audit event
    // -------------------------------------------------------------------------
    test(
      '1. Event IDS dipetakan dengan presisi menjadi SecurityAuditEvent',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );
        await coordinator.initialize();

        final idsEvent = IdsDetectionEvent(
          eventId: 'ids-evt-001',
          runId: 'RUN-EXP-01',
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          status: NodeDetectionStatus.suspected,
          observedDropRate: 0.60,
          totalExpected: 10,
          totalClaimed: 4,
          totalUnconfirmed: 6,
          totalLinkFailures: 0,
          totalProtocolDrops: 0,
          reason: 'Drop rate 0.60 melampaui batas ambang 0.35',
          timestamp: DateTime.parse('2026-10-19T11:00:00.000Z'),
          monotonicMicros: 12345,
        );

        final success = await coordinator.processIdsDetectionEvent(idsEvent);
        expect(success, isTrue);
        expect(coordinator.totalEventsReceived, equals(1));

        // Verifikasi event di dalam antrean atau blok
        final allBlocks = ledger.getAllActiveBlocks();
        // Karena status suspected, immediate flush dipicu -> langsung menjadi blok
        expect(allBlocks.length, equals(2)); // Genesis + Block 1
        final block1 = allBlocks.last;
        expect(block1.eventsCount, equals(1));
        final audit = block1.events.first;
        expect(audit.eventId, equals('ids-evt-001'));
        expect(audit.eventType, equals(AuditEventType.idsDetection));
        expect(audit.observerNodeId, equals('NODE-A'));
        expect(audit.targetNodeId, equals('NODE-B'));
        expect(audit.metadata['status'], equals('suspected'));
        expect(audit.metadata['observedDropRate'], equals(0.60));
      },
    );

    // -------------------------------------------------------------------------
    // 2. TrustScoreChangeEvent menjadi security audit event
    // -------------------------------------------------------------------------
    test(
      '2. TrustScoreChangeEvent dipetakan dengan presisi menjadi SecurityAuditEvent',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(immediateFlushOnSuspected: false),
        );
        await coordinator.initialize();

        final trustEvent = TrustScoreChangeEvent(
          eventId: 'trust-evt-001',
          runId: 'RUN-EXP-01',
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          oldScore: 0.60,
          newScore: 0.45,
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
          evaluationStatus: TrustEvaluationStatus.trusted,
          reason: 'Penalti selective forwarding pada link aktif',
          totalObservations: 6,
          positiveEvidenceSum: 3.0,
          negativeEvidenceSum: 3.0,
          linkFailureCount: 0,
          protocolDropCount: 0,
          relayClaimCount: 3,
          downstreamConfirmedCount: 0,
          deliveryConfirmedCount: 0,
          unconfirmedDropCount: 3,
          thresholdConfig: {'threshold': 0.50},
          timestamp: DateTime.parse('2026-10-19T11:05:00.000Z'),
          monotonicMicros: 23456,
        );

        final success = await coordinator.processTrustScoreChangeEvent(
          trustEvent,
        );
        expect(success, isTrue);
        expect(coordinator.totalEventsReceived, equals(1));
        expect(ledger.pendingEventsCount, equals(1));

        final audit = ledger.pendingEvents.first;
        expect(audit.eventId, equals('trust-evt-001'));
        expect(audit.eventType, equals(AuditEventType.trustUpdate));
        expect(audit.observerNodeId, equals('NODE-A'));
        expect(audit.targetNodeId, equals('NODE-B'));
        expect(audit.metadata['oldScore'], equals(0.60));
        expect(audit.metadata['newScore'], equals(0.45));
      },
    );

    // -------------------------------------------------------------------------
    // 3. Isi chat tidak terdapat pada serialized event dan blok
    // -------------------------------------------------------------------------
    test('3. Isi chat dan data pribadi tidak bocor ke dalam ledger', () async {
      final ledger = LightweightBlockdagLedger();
      final repo = LocalBlockdagRepository();
      final coordinator = BlockdagSecurityCoordinator(
        localNodeId: 'NODE-A',
        ledger: ledger,
        repository: repo,
      );
      await coordinator.initialize();

      // Tambahkan event IDS dan Trust
      await coordinator.processIdsDetectionEvent(
        IdsDetectionEvent(
          eventId: 'ids-privacy-01',
          runId: 'RUN-1',
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          status: NodeDetectionStatus.normal,
          observedDropRate: 0.1,
          totalExpected: 10,
          totalClaimed: 9,
          totalUnconfirmed: 1,
          totalLinkFailures: 0,
          totalProtocolDrops: 0,
          reason: 'Normal forwarding',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 1,
        ),
      );

      final block = await coordinator.flushPendingEvents(
        reason: 'privacy_test',
      );
      expect(block, isNotNull);

      final serializedBlock = block!.toCanonicalJson();
      final forbiddenKeywords = [
        'chat',
        'messagetext',
        'payload',
        'gps',
        'latitude',
        'longitude',
        'password',
        'privatekey',
        'korban',
        'bencana',
      ];

      for (final keyword in forbiddenKeywords) {
        expect(
          serializedBlock.toLowerCase().contains(keyword),
          isFalse,
          reason: 'Blok tidak boleh memuat kata $keyword',
        );
      }
    });

    // -------------------------------------------------------------------------
    // 4. Event ID yang sama tidak dicatat dua kali (deduplikasi)
    // -------------------------------------------------------------------------
    test('4. Event dengan eventId yang sama ditolak (anti-replay)', () async {
      final ledger = LightweightBlockdagLedger();
      final repo = LocalBlockdagRepository();
      final coordinator = BlockdagSecurityCoordinator(
        localNodeId: 'NODE-A',
        ledger: ledger,
        repository: repo,
        config: const BlockdagBatchConfig(immediateFlushOnSuspected: false),
      );
      await coordinator.initialize();

      final event = IdsDetectionEvent(
        eventId: 'dedup-check-99',
        runId: 'RUN-1',
        observerNodeId: 'NODE-A',
        targetNodeId: 'NODE-B',
        status: NodeDetectionStatus.normal,
        observedDropRate: 0.0,
        totalExpected: 5,
        totalClaimed: 5,
        totalUnconfirmed: 0,
        totalLinkFailures: 0,
        totalProtocolDrops: 0,
        reason: 'All confirmed',
        timestamp: DateTime.now().toUtc(),
        monotonicMicros: 100,
      );

      final firstAttempt = await coordinator.processIdsDetectionEvent(event);
      expect(firstAttempt, isTrue);

      final secondAttempt = await coordinator.processIdsDetectionEvent(event);
      expect(secondAttempt, isFalse);
      expect(coordinator.totalEventsRejectedOrDeduplicated, equals(1));
    });

    // -------------------------------------------------------------------------
    // 5. Event malformed ditolak
    // -------------------------------------------------------------------------
    test(
      '5. Event dengan field identitas kosong ditolak secara aman',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );
        await coordinator.initialize();

        // Event dengan eventId kosong
        final malformedEvent = IdsDetectionEvent(
          eventId: '',
          runId: 'RUN-1',
          observerNodeId: 'NODE-A',
          targetNodeId: 'NODE-B',
          status: NodeDetectionStatus.normal,
          observedDropRate: 0.0,
          totalExpected: 5,
          totalClaimed: 5,
          totalUnconfirmed: 0,
          totalLinkFailures: 0,
          totalProtocolDrops: 0,
          reason: 'Empty event ID',
          timestamp: DateTime.now().toUtc(),
          monotonicMicros: 0,
        );

        final success = await coordinator.processIdsDetectionEvent(
          malformedEvent,
        );
        expect(success, isFalse);
        expect(coordinator.totalEventsRejectedOrDeduplicated, equals(1));
        expect(ledger.pendingEventsCount, equals(0));
      },
    );

    // -------------------------------------------------------------------------
    // 6. Batch dibuat tepat satu kali saat mencapai jumlah maksimum
    // -------------------------------------------------------------------------
    test(
      '6. Blok dibuat tepat satu kali saat antrean mencapai batas batch',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(
            maxBatchSize: 4,
            immediateFlushOnSuspected: false,
          ),
        );
        await coordinator.initialize();

        for (int i = 1; i <= 4; i++) {
          final evt = IdsDetectionEvent(
            eventId: 'batch-evt-$i',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: i,
            totalClaimed: i,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Event $i',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: i * 10,
          );
          await coordinator.processIdsDetectionEvent(evt);
        }

        // Tepat pada event ke-4, blok baru dibentuk secara otomatis
        expect(coordinator.totalBlocksCreated, equals(1));
        expect(ledger.activeBlocksCount, equals(2)); // Genesis + Block 1
        expect(ledger.pendingEventsCount, equals(0));
        expect(coordinator.totalEventsCommitted, equals(4));
      },
    );

    // -------------------------------------------------------------------------
    // 7. Timer flushing berfungsi menggunakan waktu uji yang dapat dikendalikan
    // -------------------------------------------------------------------------
    test(
      '7. Timer flushing memaketkan event yang tertahan tanpa menunggu wall-clock nyata',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(
            maxBatchSize: 4,
            flushTimeout: Duration(seconds: 30),
            immediateFlushOnSuspected: false,
          ),
        );
        await coordinator.initialize();

        // Tambahkan 2 event (kurang dari maxBatchSize = 4)
        for (int i = 1; i <= 2; i++) {
          await coordinator.processIdsDetectionEvent(
            IdsDetectionEvent(
              eventId: 'timer-evt-$i',
              runId: 'RUN-1',
              observerNodeId: 'NODE-A',
              targetNodeId: 'NODE-B',
              status: NodeDetectionStatus.normal,
              observedDropRate: 0.0,
              totalExpected: i,
              totalClaimed: i,
              totalUnconfirmed: 0,
              totalLinkFailures: 0,
              totalProtocolDrops: 0,
              reason: 'Timer test $i',
              timestamp: DateTime.now().toUtc(),
              monotonicMicros: i,
            ),
          );
        }

        expect(ledger.pendingEventsCount, equals(2));
        expect(coordinator.totalBlocksCreated, equals(0));

        // Picu flushing berbasis waktu secara terkontrol
        final block = await coordinator.triggerTimeFlush();
        expect(block, isNotNull);
        expect(block!.eventsCount, equals(2));
        expect(ledger.pendingEventsCount, equals(0));
        expect(coordinator.totalBlocksCreated, equals(1));
      },
    );

    // -------------------------------------------------------------------------
    // 8. Batas batch dan timer yang terjadi bersamaan tidak menciptakan blok duplikat
    // -------------------------------------------------------------------------
    test(
      '8. Race condition batas batch dan timer tidak memicu blok ganda',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(
            maxBatchSize: 2,
            immediateFlushOnSuspected: false,
          ),
        );
        await coordinator.initialize();

        // Tambahkan 2 event sekaligus picu triggerTimeFlush secara asinkron
        final future1 = coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'race-evt-1',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: 1,
            totalClaimed: 1,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Race 1',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );
        final future2 = coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'race-evt-2',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: 2,
            totalClaimed: 2,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Race 2',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 2,
          ),
        );
        final futureFlush = coordinator.triggerTimeFlush();

        await Future.wait([future1, future2, futureFlush]);

        // Blok harus terbentuk tepat 1 kali, bukan 2 kali
        expect(coordinator.totalBlocksCreated, equals(1));
        expect(ledger.activeBlocksCount, equals(2)); // Genesis + Block 1
        expect(ledger.pendingEventsCount, equals(0));
      },
    );

    // -------------------------------------------------------------------------
    // 9. Kegagalan penulisan ledger tidak menghentikan routing
    // -------------------------------------------------------------------------
    test(
      '9. Kegagalan I/O penulisan ledger tidak memblokir atau menghentikan routing MANET',
      () async {
        final ledger = LightweightBlockdagLedger();
        final failingRepo = FailingBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: failingRepo,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coordinator.initialize();

        // Tambahkan event ke coordinator dengan repository yang gagal
        final ok = await coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'fail-io-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 4,
            totalClaimed: 2,
            totalUnconfirmed: 2,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Test fail',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );

        // Event diterima, pembentukan blok berjalan, kegagalan persistensi dicatat
        expect(ok, isTrue);
        expect(coordinator.totalPersistenceFailures, greaterThan(0));

        // Verifikasi routing engine tetap dapat meneruskan pesan normal tanpa crash
        final fakeTransport = FakeMeshTransport();
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-B',
            endpointName: 'Node B',
            serviceId: 'siagamesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );
        final engine = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-A',
            overrideName: 'Node A',
          ),
          repository: LocalChatRepository(),
        );
        engine.neighborTable.mapIdentity(
          endpointId: 'ep-B',
          nodeId: 'NODE-B',
          nodeName: 'Node B',
        );

        final envelope = await engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan darurat tetap terkirim lancar',
        );

        expect(envelope, isNotNull);
        expect(fakeTransport.sentPayloads.length, equals(1));
        engine.dispose();
        fakeTransport.dispose();
      },
    );

    // -------------------------------------------------------------------------
    // 10. Ledger dapat dipulihkan setelah repository dibuat ulang
    // -------------------------------------------------------------------------
    test(
      '10. Pemulihan ledger dari repository mengembalikan seluruh blok dan relasi DAG',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repo1 = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger1 = LightweightBlockdagLedger();
        final coord1 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger1,
          repository: repo1,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coord1.initialize();

        await coord1.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'restore-evt-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 4,
            totalClaimed: 2,
            totalUnconfirmed: 2,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Restore test',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );

        final savedBlockHash = ledger1.tipHashes.first;

        // Buat instance baru (simulasi restart aplikasi) dengan SharedPreferences yang sama
        final repo2 = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger2 = LightweightBlockdagLedger();
        final coord2 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger2,
          repository: repo2,
        );
        final restoreStatus = await coord2.initialize();

        expect(restoreStatus, equals(BlockdagInitStatus.restoredFromStorage));
        expect(
          coord2.initStatus,
          equals(BlockdagInitStatus.restoredFromStorage),
        );
        expect(ledger2.activeBlocksCount, equals(2));
        expect(ledger2.tipHashes, contains(savedBlockHash));
        expect(ledger2.processedEventIds, contains('restore-evt-01'));
      },
    );

    // -------------------------------------------------------------------------
    // 11. Data tersimpan rusak ditangani secara eksplisit dan aman
    // -------------------------------------------------------------------------
    test(
      '11. Data tersimpan korup ditangani secara aman tanpa melempar uncaught exception',
      () async {
        // Siapkan SharedPreferences dengan format data JSON rusak
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keyState:
              '{invalid_json_corrupted_data: true,',
          LocalBlockdagRepository.keySchemaVersion: 1,
        });

        final repo = LocalBlockdagRepository();
        final state = await repo.loadState();
        expect(state, isNull);
        expect(repo.lastLoadCorrupted, isTrue);

        final ledger = LightweightBlockdagLedger();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        // Inisialisasi harus berjalan lancar dan menghasilkan genesis bersih dengan status corruptedFallbackGenesis
        final initStatus = await coordinator.initialize();
        expect(initStatus, equals(BlockdagInitStatus.corruptedFallbackGenesis));
        expect(
          coordinator.initStatus,
          equals(BlockdagInitStatus.corruptedFallbackGenesis),
        );
        expect(ledger.activeBlocksCount, equals(1)); // Genesis block
        expect(ledger.tipHashes.length, equals(1));
      },
    );

    // -------------------------------------------------------------------------
    // 12. Event yang belum tersimpan tidak hilang tanpa pencatatan kegagalan
    // -------------------------------------------------------------------------
    test(
      '12. Event pending dipertahankan dalam memori jika persistensi gagal',
      () async {
        final ledger = LightweightBlockdagLedger();
        final failingRepo = FailingBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: failingRepo,
          config: const BlockdagBatchConfig(
            maxBatchSize: 10,
            immediateFlushOnSuspected: false,
          ),
        );
        await coordinator.initialize();

        await coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'pending-survive-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: 2,
            totalClaimed: 2,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Keep pending',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );

        // Event tetap berada di pending buffer
        expect(ledger.pendingEventsCount, equals(1));
        expect(
          ledger.pendingEvents.first.eventId,
          equals('pending-survive-01'),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 13. Retensi dan checkpoint tetap konsisten setelah restore
    // -------------------------------------------------------------------------
    test(
      '13. Checkpoint jangkar dan pemangkasan tetap konsisten pasca pemulihan',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repo = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger = LightweightBlockdagLedger(maxRetentionBlocks: 3);
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coordinator.initialize();

        // Tambahkan 5 blok linier (memicu pemangkasan)
        for (int i = 1; i <= 5; i++) {
          await coordinator.processIdsDetectionEvent(
            IdsDetectionEvent(
              eventId: 'prune-seq-$i',
              runId: 'RUN-1',
              observerNodeId: 'NODE-A',
              targetNodeId: 'NODE-B',
              status: NodeDetectionStatus.suspected,
              observedDropRate: 0.5,
              totalExpected: i,
              totalClaimed: i,
              totalUnconfirmed: 0,
              totalLinkFailures: 0,
              totalProtocolDrops: 0,
              reason: 'Prune $i',
              timestamp: DateTime.now().toUtc(),
              monotonicMicros: i,
            ),
          );
        }

        expect(ledger.activeBlocksCount, equals(3));
        expect(ledger.checkpoints.isNotEmpty, isTrue);
        final originalCheckpointsCount = ledger.checkpoints.length;
        final originalRetainedBase =
            ledger.checkpoints.last.retainedGenesisHash;

        // Pulihkan ke instance baru
        final restoredLedger = LightweightBlockdagLedger(maxRetentionBlocks: 3);
        final restoredCoord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: restoredLedger,
          repository: repo,
        );
        await restoredCoord.initialize();

        expect(restoredLedger.activeBlocksCount, equals(3));
        expect(
          restoredLedger.checkpoints.length,
          equals(originalCheckpointsCount),
        );
        expect(
          restoredLedger.checkpoints.last.retainedGenesisHash,
          equals(originalRetainedBase),
        );
      },
    );

    // -------------------------------------------------------------------------
    // 14. Deduplikasi tetap bekerja setelah restart sesuai cakupan retensi
    // -------------------------------------------------------------------------
    test(
      '14. Cache deduplikasi mencegah re-injeksi event historis pasca restart',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repo = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger1 = LightweightBlockdagLedger();
        final coord1 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger1,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coord1.initialize();

        await coord1.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'restart-dedup-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 2,
            totalClaimed: 2,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Before restart',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );

        // Mulai ulang sesi pada instance kedua
        final ledger2 = LightweightBlockdagLedger();
        final coord2 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger2,
          repository: repo,
        );
        await coord2.initialize();

        // Coba masukkan kembali event dengan ID yang sama
        final reInjected = await coord2.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'restart-dedup-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 2,
            totalClaimed: 2,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Replay after restart',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 2,
          ),
        );

        expect(reInjected, isFalse);
        expect(coord2.totalEventsRejectedOrDeduplicated, equals(1));
      },
    );

    // -------------------------------------------------------------------------
    // 15. Konfigurasi A tidak bergantung pada ledger
    // -------------------------------------------------------------------------
    test(
      '15. Konfigurasi A (Baseline) meneruskan paket tanpa inisialisasi ledger',
      () async {
        final fakeTransport = FakeMeshTransport();
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-B',
            endpointName: 'Node B',
            serviceId: 'siagamesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );

        // Konfigurasi A: Tanpa IDS, tanpa Trust, tanpa Blockchain
        final routingEngine = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-A',
            overrideName: 'Node A',
          ),
          repository: LocalChatRepository(),
          idsDetector: null,
          trustManager: null,
        );
        routingEngine.neighborTable.mapIdentity(
          endpointId: 'ep-B',
          nodeId: 'NODE-B',
          nodeName: 'Node B',
        );

        final envelope = await routingEngine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan Baseline MANET',
        );

        expect(envelope, isNotNull);
        expect(fakeTransport.sentPayloads.length, equals(1));
        expect(ManetRoutingHolder.blockdagCoordinator, isNull);
        routingEngine.dispose();
        fakeTransport.dispose();
      },
    );

    // -------------------------------------------------------------------------
    // 16. Konfigurasi B dapat berjalan tanpa ledger
    // -------------------------------------------------------------------------
    test(
      '16. Konfigurasi B (IDS + Trust) berjalan sempurna tanpa modul ledger',
      () async {
        final fakeTransport = FakeMeshTransport();
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-B',
            endpointName: 'Node B',
            serviceId: 'siagamesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );

        final detector = SelectiveForwardingDetector(localNodeId: 'NODE-A');
        final trustManager = DynamicTrustManager(localNodeId: 'NODE-A');

        final routingEngine = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-A',
            overrideName: 'Node A',
          ),
          repository: LocalChatRepository(),
          idsDetector: detector,
          trustManager: trustManager,
          enableHopAck: true,
          enableTrustRoutingPolicy: true,
        );
        routingEngine.neighborTable.mapIdentity(
          endpointId: 'ep-B',
          nodeId: 'NODE-B',
          nodeName: 'Node B',
        );

        // Simulasikan pengamatan drop pada node B
        trustManager.observeDirectEvidence(
          targetNodeId: 'NODE-B',
          evidenceId: 'ev-config-b-01',
          evidenceType: ForwardingEvidenceType.forwardingUnconfirmed,
        );

        expect(trustManager.getTrustScore('NODE-B'), lessThan(0.60));
        expect(ManetRoutingHolder.blockdagCoordinator, isNull);
        routingEngine.dispose();
        fakeTransport.dispose();
        detector.dispose();
        trustManager.dispose();
      },
    );

    // -------------------------------------------------------------------------
    // 17. Konfigurasi C mencatat event IDS dan trust
    // -------------------------------------------------------------------------
    test(
      '17. Konfigurasi C mencatat aliran event IDS dan Trust secara otomatis',
      () async {
        final detector = SelectiveForwardingDetector(
          localNodeId: 'NODE-A',
          config: const IdsConfig(minObservationsForEvaluation: 1),
        );
        final trustManager = DynamicTrustManager(localNodeId: 'NODE-A');

        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(
            maxBatchSize: 2,
            immediateFlushOnSuspected: false,
          ),
        );
        await coordinator.initialize();

        // Hubungkan coordinator ke detektor dan trust manager
        coordinator.attachToDetector(detector);
        coordinator.attachToTrustManager(trustManager);

        // 1. Picu event trust
        trustManager.observeDirectEvidence(
          targetNodeId: 'NODE-B',
          evidenceId: 'config-c-trust-01',
          evidenceType: ForwardingEvidenceType.relayClaimed,
        );

        // 2. Picu event IDS
        detector.registerForwardingExpected(
          peerNodeId: 'NODE-B',
          envelopeId: 'config-c-ids-01',
        );
        detector.registerForwardingConfirmed(
          peerNodeId: 'NODE-B',
          envelopeId: 'config-c-ids-01',
        );

        // Tunggu aliran event diproses broadcast controller
        await pumpEventQueue();

        // Batch size 2 terpenuhi -> otomatis membuat blok
        expect(coordinator.totalEventsReceived, equals(2));
        expect(coordinator.totalBlocksCreated, equals(1));
        expect(ledger.activeBlocksCount, equals(2)); // Genesis + Block 1

        final block1 = ledger.getAllActiveBlocks().last;
        expect(block1.eventsCount, equals(2));
        expect(
          block1.events.any((e) => e.eventType == AuditEventType.trustUpdate),
          isTrue,
        );
        expect(
          block1.events.any((e) => e.eventType == AuditEventType.idsDetection),
          isTrue,
        );

        coordinator.dispose();
        detector.dispose();
        trustManager.dispose();
      },
    );

    // -------------------------------------------------------------------------
    // 18. Instrumentasi metrik dan verifikasi non-interferensi
    // -------------------------------------------------------------------------
    test(
      '18. Instrumentasi metrik lokal akurat dan tidak mencampuri state routing',
      () async {
        final ledger = LightweightBlockdagLedger();
        final repo = LocalBlockdagRepository();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 2),
        );
        await coordinator.initialize();

        await coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'metric-evt-1',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: 1,
            totalClaimed: 1,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Metric 1',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 10,
          ),
        );

        await coordinator.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'metric-evt-2',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.normal,
            observedDropRate: 0.0,
            totalExpected: 2,
            totalClaimed: 2,
            totalUnconfirmed: 0,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Metric 2',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 20,
          ),
        );

        final metrics = coordinator.getMetrics();
        expect(metrics['totalEventsReceived'], equals(2));
        expect(metrics['totalBlocksCreated'], equals(1));
        expect(metrics['totalEventsCommitted'], equals(2));
        expect(metrics['averageEventsPerBlock'], equals(2.0));
        expect(metrics['totalPersistenceFailures'], equals(0));
        expect(metrics['estimatedStorageSizeBytes'], greaterThan(0));
      },
    );
  });

  group('STAGE 5E.3.2 — Persistence Initialization & Schema Integrity Hardening', () {
    test(
      '19. Instalasi baru dengan storage tersedia menghasilkan freshGenesis',
      () async {
        SharedPreferences.setMockInitialValues({});
        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.empty));
        expect(loadRes.isEmpty, isTrue);

        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        final status = await coord.initialize();
        expect(status, equals(BlockdagInitStatus.freshGenesis));
        expect(coord.isInitialized, isTrue);
        expect(ledger.activeBlocksCount, equals(1)); // Genesis block
        expect(repo.lastLoadCorrupted, isFalse);

        final secondLoad = await repo.loadResult();
        expect(secondLoad.status, equals(BlockdagLoadStatus.success));
        expect(secondLoad.state?.schemaVersion, equals(1));
      },
    );

    test(
      '20. Kegagalan inisialisasi SharedPreferences menghasilkan storageUnavailable',
      () async {
        final repo = LocalBlockdagRepository(simulateStorageUnavailable: true);
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.storageUnavailable));
        expect(loadRes.isStorageUnavailable, isTrue);
        expect(repo.lastLoadCorrupted, isFalse);

        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        final status = await coord.initialize();
        expect(status, equals(BlockdagInitStatus.storageUnavailable));
        expect(coord.isInitialized, isFalse); // Memungkinkan retry
        expect(coord.totalPersistenceFailures, equals(1));
        expect(repo.lastLoadCorrupted, isFalse); // Bukan korupsi data
      },
    );

    test(
      '21. schemaVersion hilang dari JSON ditandai sebagai data korup',
      () async {
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keyState: jsonEncode({
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
            // 'schemaVersion' sengaja dihilangkan
          }),
          LocalBlockdagRepository.keySchemaVersion: 1,
        });

        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.corruptedData));
        expect(loadRes.isCorrupted, isTrue);
        expect(repo.lastLoadCorrupted, isTrue);

        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        final status = await coord.initialize();
        expect(status, equals(BlockdagInitStatus.corruptedFallbackGenesis));
        expect(coord.isInitialized, isTrue);
        expect(ledger.activeBlocksCount, equals(1));
      },
    );

    test(
      '22. schemaVersion bernilai nol atau negatif ditandai sebagai data korup',
      () async {
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keyState: jsonEncode({
            'schemaVersion': 0, // Tidak valid
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
          LocalBlockdagRepository.keySchemaVersion: 0,
        });

        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.corruptedData));
        expect(repo.lastLoadCorrupted, isTrue);
      },
    );

    test(
      '23. Ketidakcocokan versi skema antara SharedPreferences dan JSON state ditandai sebagai korup',
      () async {
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keySchemaVersion:
              1, // Di prefs tercatat versi 1
          LocalBlockdagRepository.keyState: jsonEncode({
            'schemaVersion': 2, // Namun di state tercatat versi 2
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        });

        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.corruptedData));
        expect(loadRes.errorMessage, contains('Ketidakcocokan versi skema'));
        expect(repo.lastLoadCorrupted, isTrue);
      },
    );

    test(
      '24. Versi skema tidak didukung menghentikan inisialisasi tanpa menimpa data',
      () async {
        final preservedPayload = jsonEncode({
          'schemaVersion': 2, // Versi masa depan
          'blocks': [],
          'checkpoints': [],
          'tipHashes': ['tip-future-99'],
          'processedBlockHashes': [],
          'processedEventIds': [],
          'pendingEvents': [],
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        });

        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keySchemaVersion: 2,
          LocalBlockdagRepository.keyState: preservedPayload,
        });

        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.unsupportedVersion));
        expect(loadRes.isUnsupportedVersion, isTrue);
        expect(loadRes.detectedSchemaVersion, equals(2));
        expect(repo.lastLoadCorrupted, isFalse);

        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        final status = await coord.initialize();
        expect(status, equals(BlockdagInitStatus.unsupportedVersionHalted));
        expect(coord.isInitialized, isFalse);

        // Verifikasi data pada SharedPreferences TIDAK tertimpa oleh Genesis baru
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(LocalBlockdagRepository.keyState),
          equals(preservedPayload),
        );
        expect(
          prefs.getInt(LocalBlockdagRepository.keySchemaVersion),
          equals(2),
        );
      },
    );

    test(
      '25. Penulisan Genesis awal gagal menghasilkan genesisPersistenceFailed dan memungkinkan retry',
      () async {
        final failingRepo = FailingBlockdagRepository();
        failingRepo.loadResultStub = BlockdagLoadResult.empty();

        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: failingRepo,
        );

        final status = await coord.initialize();
        expect(status, equals(BlockdagInitStatus.genesisPersistenceFailed));
        expect(coord.isInitialized, isFalse); // Memungkinkan retry
        expect(coord.totalPersistenceFailures, greaterThan(0));
      },
    );

    test(
      '26. Storage pulih dari pemadaman sementara dan pemulihan berhasil pada retry',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repoHealthy = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger1 = LightweightBlockdagLedger();
        final coord1 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger1,
          repository: repoHealthy,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coord1.initialize();

        // Tambahkan 1 blok dengan hash unik
        await coord1.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'retry-evt-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 2,
            totalClaimed: 1,
            totalUnconfirmed: 1,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Retry test event',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );
        final savedBlockHash = ledger1.tipHashes.first;

        // Buat repo baru dengan simulasi storage unavailable
        final dynamicRepo = LocalBlockdagRepository(
          preferences: sharedPrefs,
          simulateStorageUnavailable: true,
        );
        final ledger2 = LightweightBlockdagLedger();
        final coord2 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger2,
          repository: dynamicRepo,
        );

        // Percobaan inisialisasi pertama: Gagal karena storage tidak tersedia
        final firstAttempt = await coord2.initialize();
        expect(firstAttempt, equals(BlockdagInitStatus.storageUnavailable));
        expect(coord2.isInitialized, isFalse);

        // Simulasikan storage kembali tersedia (pulih)
        dynamicRepo.simulateStorageUnavailable = false;

        // Percobaan inisialisasi kedua (Retry): Berhasil memulihkan state lama
        final retryAttempt = await coord2.initialize();
        expect(retryAttempt, equals(BlockdagInitStatus.restoredFromStorage));
        expect(coord2.isInitialized, isTrue);
        expect(ledger2.activeBlocksCount, equals(2)); // Genesis + Block 1
        expect(ledger2.tipHashes, contains(savedBlockHash));
      },
    );

    test(
      '27. State lama tidak tertimpa Genesis selama storage tidak dapat diakses',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repo = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger = LightweightBlockdagLedger();
        final coord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coord.initialize();

        await coord.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'protected-evt-01',
            runId: 'RUN-1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.5,
            totalExpected: 2,
            totalClaimed: 1,
            totalUnconfirmed: 1,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'Preserve test',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 1,
          ),
        );

        final stateBeforeOutage = sharedPrefs.getString(
          LocalBlockdagRepository.keyState,
        );
        expect(stateBeforeOutage, isNotNull);
        expect(stateBeforeOutage, contains('protected-evt-01'));

        // Simulasikan node reboot saat storage error
        final offlineRepo = LocalBlockdagRepository(
          preferences: sharedPrefs,
          simulateStorageUnavailable: true,
        );
        final offlineLedger = LightweightBlockdagLedger();
        final offlineCoord = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: offlineLedger,
          repository: offlineRepo,
        );

        final status = await offlineCoord.initialize();
        expect(status, equals(BlockdagInitStatus.storageUnavailable));

        // Verifikasi string state di SharedPreferences tetap utuh dan tidak ditimpa
        final stateAfterFailedInit = sharedPrefs.getString(
          LocalBlockdagRepository.keyState,
        );
        expect(stateAfterFailedInit, equals(stateBeforeOutage));
      },
    );

    test(
      '28. Routing engine MANET tetap beroperasi normal saat ledger mengalami kegagalan inisialisasi',
      () async {
        final offlineRepo = LocalBlockdagRepository(
          simulateStorageUnavailable: true,
        );
        final ledger = LightweightBlockdagLedger();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: offlineRepo,
        );
        final initStatus = await coordinator.initialize();
        expect(initStatus, equals(BlockdagInitStatus.storageUnavailable));

        // Hubungkan coordinator ke ManetRoutingHolder
        ManetRoutingHolder.setBlockdagCoordinator(coordinator);

        // Verifikasi routing engine tetap dapat mengirim pesan tanpa terpengaruh kegagalan storage ledger
        final fakeTransport = FakeMeshTransport();
        fakeTransport.simulatePeerDiscovered(
          DiscoveredPeer(
            endpointId: 'ep-B',
            endpointName: 'Node B',
            serviceId: 'siagamesh',
            discoveredAt: DateTime.now(),
            status: PeerConnectionStatus.connected,
          ),
        );
        final engine = ManetRoutingEngine(
          transport: fakeTransport,
          identityManager: NodeIdentityManager(
            overrideId: 'NODE-A',
            overrideName: 'Node A',
          ),
          repository: LocalChatRepository(),
        );
        engine.neighborTable.mapIdentity(
          endpointId: 'ep-B',
          nodeId: 'NODE-B',
          nodeName: 'Node B',
        );

        final envelope = await engine.sendChatMessage(
          recipientNodeId: 'NODE-B',
          text: 'Pesan darurat berhasil dikirim meski storage ledger offline',
        );

        expect(envelope, isNotNull);
        expect(fakeTransport.sentPayloads.length, equals(1));

        engine.dispose();
        fakeTransport.dispose();
        coordinator.dispose();
      },
    );
  });

  group('STAGE 5E.3.3 — Strict Schema Version Validation', () {
    test(
      '29. BlockdagPersistedState.fromMap menolak schemaVersion pecahan, nol, negatif, string, boolean, dan non-finite',
      () {
        Map<String, dynamic> createBaseMap(dynamic version) => {
          if (version != 'OMIT') 'schemaVersion': version,
          'blocks': [],
          'checkpoints': [],
          'tipHashes': [],
          'processedBlockHashes': [],
          'processedEventIds': [],
          'pendingEvents': [],
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        };

        // 1. Pecahan ditolak
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(1.5)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('pecahan'),
            ),
          ),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(0.1)),
          throwsA(isA<FormatException>()),
        );

        // 2. Nol dan negatif ditolak
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(0)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('positif'),
            ),
          ),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(-1)),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(-1.5)),
          throwsA(isA<FormatException>()),
        );

        // 3. Field hilang atau null ditolak
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(null)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('wajib ada'),
            ),
          ),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap('OMIT')),
          throwsA(isA<FormatException>()),
        );

        // 4. String dan boolean ditolak
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap('1')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('numerik integer'),
            ),
          ),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(true)),
          throwsA(isA<FormatException>()),
        );

        // 5. Non-finite ditolak
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(double.nan)),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('NaN atau Infinity'),
            ),
          ),
        );
        expect(
          () => BlockdagPersistedState.fromMap(createBaseMap(double.infinity)),
          throwsA(isA<FormatException>()),
        );

        // 6. Versi positif integer valid 1 diterima
        final stateV1 = BlockdagPersistedState.fromMap(createBaseMap(1));
        expect(stateV1.schemaVersion, equals(1));

        // 7. Versi integer bulat lebih tinggi 2 diterima oleh parser (nantinya ditolak oleh repository)
        final stateV2 = BlockdagPersistedState.fromMap(createBaseMap(2));
        expect(stateV2.schemaVersion, equals(2));
      },
    );

    test(
      '30. LocalBlockdagRepository.loadResult menolak schemaVersion pecahan (1.5) sebagai corruptedData',
      () async {
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keySchemaVersion: 1,
          LocalBlockdagRepository.keyState: jsonEncode({
            'schemaVersion': 1.5,
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        });

        final repo = LocalBlockdagRepository();
        final loadRes = await repo.loadResult();
        expect(loadRes.status, equals(BlockdagLoadStatus.corruptedData));
        expect(loadRes.isCorrupted, isTrue);
        expect(loadRes.errorMessage, contains('pecahan'));
        expect(repo.lastLoadCorrupted, isTrue);
      },
    );

    test(
      '31. LocalBlockdagRepository.loadResult menolak schemaVersion bertipe string dan boolean',
      () async {
        // String
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keyState: jsonEncode({
            'schemaVersion': '1',
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        });

        final repo1 = LocalBlockdagRepository();
        final loadRes1 = await repo1.loadResult();
        expect(loadRes1.status, equals(BlockdagLoadStatus.corruptedData));
        expect(loadRes1.errorMessage, contains('numerik'));

        // Boolean
        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keyState: jsonEncode({
            'schemaVersion': false,
            'blocks': [],
            'checkpoints': [],
            'tipHashes': [],
            'processedBlockHashes': [],
            'processedEventIds': [],
            'pendingEvents': [],
            'savedAt': DateTime.now().toUtc().toIso8601String(),
          }),
        });

        final repo2 = LocalBlockdagRepository();
        final loadRes2 = await repo2.loadResult();
        expect(loadRes2.status, equals(BlockdagLoadStatus.corruptedData));
        expect(loadRes2.errorMessage, contains('numerik'));
      },
    );

    test(
      '32. Versi skema bulat lebih tinggi (versi 2 dan 99) menghasilkan unsupportedVersion tanpa fallback diam-diam',
      () async {
        for (final unsupportedVer in [2, 99]) {
          SharedPreferences.setMockInitialValues({
            LocalBlockdagRepository.keySchemaVersion: unsupportedVer,
            LocalBlockdagRepository.keyState: jsonEncode({
              'schemaVersion': unsupportedVer,
              'blocks': [],
              'checkpoints': [],
              'tipHashes': ['tip-future-$unsupportedVer'],
              'processedBlockHashes': [],
              'processedEventIds': [],
              'pendingEvents': [],
              'savedAt': DateTime.now().toUtc().toIso8601String(),
            }),
          });

          final repo = LocalBlockdagRepository();
          final loadRes = await repo.loadResult();
          expect(loadRes.status, equals(BlockdagLoadStatus.unsupportedVersion));
          expect(loadRes.isUnsupportedVersion, isTrue);
          expect(loadRes.detectedSchemaVersion, equals(unsupportedVer));
          expect(
            repo.lastLoadCorrupted,
            isFalse,
          ); // Bukan korupsi, melainkan versi masa depan
        }
      },
    );

    test(
      '33. State dengan versi tidak didukung tidak dihapus atau ditimpa oleh Genesis baru',
      () async {
        final futurePayload = jsonEncode({
          'schemaVersion': 2,
          'blocks': [],
          'checkpoints': [],
          'tipHashes': ['tip-preserved-state'],
          'processedBlockHashes': [],
          'processedEventIds': [],
          'pendingEvents': [],
          'savedAt': DateTime.now().toUtc().toIso8601String(),
        });

        SharedPreferences.setMockInitialValues({
          LocalBlockdagRepository.keySchemaVersion: 2,
          LocalBlockdagRepository.keyState: futurePayload,
        });

        final repo = LocalBlockdagRepository();
        final ledger = LightweightBlockdagLedger();
        final coordinator = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger,
          repository: repo,
        );

        final status = await coordinator.initialize();
        expect(status, equals(BlockdagInitStatus.unsupportedVersionHalted));
        expect(coordinator.isInitialized, isFalse);

        // Verifikasi pada storage disk nyata: payload tidak boleh terhapus atau berubah
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(LocalBlockdagRepository.keyState),
          equals(futurePayload),
        );
        expect(
          prefs.getInt(LocalBlockdagRepository.keySchemaVersion),
          equals(2),
        );
      },
    );

    test(
      '34. Pemulihan state valid yang sudah tersimpan (versi 1) tetap berfungsi sempurna',
      () async {
        final sharedPrefs = await SharedPreferences.getInstance();
        final repo = LocalBlockdagRepository(preferences: sharedPrefs);
        final ledger1 = LightweightBlockdagLedger();
        final coord1 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger1,
          repository: repo,
          config: const BlockdagBatchConfig(maxBatchSize: 1),
        );
        await coord1.initialize();

        await coord1.processIdsDetectionEvent(
          IdsDetectionEvent(
            eventId: 'v1-persisted-evt',
            runId: 'RUN-V1',
            observerNodeId: 'NODE-A',
            targetNodeId: 'NODE-B',
            status: NodeDetectionStatus.suspected,
            observedDropRate: 0.6,
            totalExpected: 5,
            totalClaimed: 2,
            totalUnconfirmed: 3,
            totalLinkFailures: 0,
            totalProtocolDrops: 0,
            reason: 'V1 validation test',
            timestamp: DateTime.now().toUtc(),
            monotonicMicros: 999,
          ),
        );

        // Verifikasi bahwa state tersimpan dengan schemaVersion: 1
        final rawJson = sharedPrefs.getString(LocalBlockdagRepository.keyState);
        expect(rawJson, isNotNull);
        final decoded = jsonDecode(rawJson!) as Map<String, dynamic>;
        expect(decoded['schemaVersion'], equals(1));
        expect(
          sharedPrefs.getInt(LocalBlockdagRepository.keySchemaVersion),
          equals(1),
        );

        // Pulihkan pada instance kedua
        final ledger2 = LightweightBlockdagLedger();
        final coord2 = BlockdagSecurityCoordinator(
          localNodeId: 'NODE-A',
          ledger: ledger2,
          repository: repo,
        );

        final initStatus = await coord2.initialize();
        expect(initStatus, equals(BlockdagInitStatus.restoredFromStorage));
        expect(coord2.isInitialized, isTrue);
        expect(ledger2.activeBlocksCount, equals(2));
        expect(ledger2.processedEventIds, contains('v1-persisted-evt'));
      },
    );
  });
}
