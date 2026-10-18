import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:siagamesh_app/core/transport/fake_mesh_transport.dart';
import 'package:siagamesh_app/core/transport/mesh_transport.dart';
import 'package:siagamesh_app/core/transport/transport_payload_envelope.dart';
import 'package:siagamesh_app/features/chat/models/chat_message.dart';
import 'package:siagamesh_app/features/mesh_devices/models/mesh_node.dart';

void main() {
  group('STAGE 5B.1 — Pengujian Unit Transport 1-Hop SiagaMesh', () {
    late FakeMeshTransport transport;

    setUp(() {
      transport = FakeMeshTransport();
    });

    tearDown(() {
      transport.dispose();
    });

    test('1. Mengirim payload ke peer yang berstatus connected', () async {
      // Siapkan peer dengan status connected
      final connectedPeer = DiscoveredPeer(
        endpointId: 'ep-galaxy-a54',
        endpointName: 'Galaxy A54',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.connected,
      );
      transport.simulatePeerDiscovered(connectedPeer);

      // Buat envelope payload 1-hop
      final envelope = OneHopPayloadEnvelope(
        messageId: 'msg-test-101',
        type: 'CHAT_1HOP',
        senderNodeId: 'node-local',
        senderName: 'Penguji A',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        text: 'Pesan uji coba 1-hop langsung',
      );

      // Kirim bytes
      final result = await transport.sendBytes(
        endpointId: 'ep-galaxy-a54',
        bytes: envelope.toBytes(),
      );

      expect(result, isTrue);
      expect(transport.sentPayloads.length, equals(1));
      expect(transport.sentPayloads.first.endpointId, equals('ep-galaxy-a54'));

      // Verifikasi isi payload yang terkirim
      final sentEnvelope = OneHopPayloadEnvelope.fromBytes(
        transport.sentPayloads.first.bytes,
      );
      expect(sentEnvelope, isNotNull);
      expect(sentEnvelope!.text, equals('Pesan uji coba 1-hop langsung'));
      expect(sentEnvelope.messageId, equals('msg-test-101'));
    });

    test('2. Menolak pengiriman ketika koneksi belum aktif', () async {
      // Peer masih berstatus disconnected
      final disconnectedPeer = DiscoveredPeer(
        endpointId: 'ep-redmi-12',
        endpointName: 'Redmi Note 12',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.disconnected,
      );
      transport.simulatePeerDiscovered(disconnectedPeer);

      final envelope = OneHopPayloadEnvelope(
        messageId: 'msg-test-102',
        type: 'CHAT_1HOP',
        senderNodeId: 'node-local',
        senderName: 'Penguji A',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        text: 'Pesan ke perangkat belum terhubung',
      );

      // Pengiriman harus ditolak
      final result = await transport.sendBytes(
        endpointId: 'ep-redmi-12',
        bytes: envelope.toBytes(),
      );

      expect(result, isFalse);
      expect(transport.sentPayloads.isEmpty, isTrue);

      // Pengiriman ke endpoint yang tidak ada sama sekali juga harus ditolak
      final nonExistentResult = await transport.sendBytes(
        endpointId: 'ep-unknown-999',
        bytes: envelope.toBytes(),
      );
      expect(nonExistentResult, isFalse);
    });

    test('3. Menangani payload valid dan JSON rusak secara aman', () {
      // 3.1 Payload Valid dengan Telemetri
      final validEnvelope = OneHopPayloadEnvelope(
        messageId: 'msg-telemetry-01',
        type: 'CHAT_1HOP',
        senderNodeId: 'node-sar-01',
        senderName: 'Tim SAR 1',
        timestamp: 1718293840000,
        text: 'Laporan koordinat evakuasi',
        telemetry: const TelemetryData(
          locationName: 'Jembatan Barat',
          latitude: -6.2001,
          longitude: 106.8123,
          accuracy: '±4m',
          priority: 'TINGGI',
          validationInfo: 'GPS Valid',
        ),
      );

      final validBytes = validEnvelope.toBytes();
      final parsed = OneHopPayloadEnvelope.fromBytes(validBytes);
      expect(parsed, isNotNull);
      expect(parsed!.senderNodeId, equals('node-sar-01'));
      expect(parsed.telemetry, isNotNull);
      expect(parsed.telemetry!.locationName, equals('Jembatan Barat'));

      // 3.2 JSON Korup
      final corruptedBytes = Uint8List.fromList(
        utf8.encode('{ "corrupted": [unclosed_bracket,,, %%%'),
      );
      final corruptResult = OneHopPayloadEnvelope.fromBytes(corruptedBytes);
      expect(corruptResult, isNull);

      // 3.3 Payload Kosong
      final emptyBytes = Uint8List(0);
      final emptyResult = OneHopPayloadEnvelope.fromBytes(emptyBytes);
      expect(emptyResult, isNull);

      // 3.4 Payload melebihi batas ukuran (32 KB)
      final oversizedBytes = Uint8List(
        OneHopPayloadEnvelope.maxPayloadSizeBytes + 100,
      );
      final oversizedResult = OneHopPayloadEnvelope.fromBytes(oversizedBytes);
      expect(oversizedResult, isNull);
    });

    test(
      '4. Memperbarui status koneksi saat peer terhubung atau terputus',
      () async {
        final events = <TransportConnectionEvent>[];
        final sub = transport.connectionEventsStream.listen(events.add);

        // Simulasi peer ditemukan
        final peer = DiscoveredPeer(
          endpointId: 'ep-test-01',
          endpointName: 'Node Uji 1',
          serviceId: 'com.siagamesh.emergency.mesh',
          discoveredAt: DateTime.now(),
          status: PeerConnectionStatus.disconnected,
        );
        transport.simulatePeerDiscovered(peer);

        // Request connection
        await transport.requestConnection(
          endpointId: 'ep-test-01',
          localNodeName: 'Penguji Lokal',
        );
        expect(
          transport.currentPeers.first.status,
          equals(PeerConnectionStatus.connecting),
        );

        // Accept connection
        await transport.acceptConnection(endpointId: 'ep-test-01');
        expect(
          transport.currentPeers.first.status,
          equals(PeerConnectionStatus.connected),
        );
        expect(transport.connectedPeers.length, equals(1));

        // Disconnect
        await transport.disconnect(endpointId: 'ep-test-01');
        expect(
          transport.currentPeers.first.status,
          equals(PeerConnectionStatus.disconnected),
        );
        expect(transport.connectedPeers.isEmpty, isTrue);

        await sub.cancel();
      },
    );

    test('5. Membersihkan resource ketika transport dihentikan', () async {
      await transport.startAdvertising(localNodeName: 'Node-A');
      await transport.startDiscovery();
      transport.simulatePeerDiscovered(
        DiscoveredPeer(
          endpointId: 'ep-active-1',
          endpointName: 'Node Aktif',
          serviceId: 'service',
          discoveredAt: DateTime.now(),
          status: PeerConnectionStatus.connected,
        ),
      );

      expect(transport.isAdvertising, isTrue);
      expect(transport.isDiscovering, isTrue);
      expect(transport.currentPeers.isNotEmpty, isTrue);

      // Hentikan semua
      await transport.stopAll();

      expect(transport.isAdvertising, isFalse);
      expect(transport.isDiscovering, isFalse);
      expect(transport.currentPeers.isEmpty, isTrue);
    });

    test('6. Memastikan data mock tidak dilabeli sebagai koneksi fisik', () {
      // Verifikasi model node mock bawaan
      const mockNode = MeshNode(
        id: 'node-mock-1',
        name: 'Posko Relawan Utama',
        distanceText: 'Jarak: ~15 meter',
        signalQuality: 'Kuat',
        status: MeshNodeStatus.connected,
        subInfo: 'Kanal Darurat Aktif',
      );

      // Model mock MeshNode memiliki struktur terpisah dari DiscoveredPeer fisik
      expect(mockNode.id, equals('node-mock-1'));
      expect(mockNode.status, equals(MeshNodeStatus.connected));

      // DiscoveredPeer fisik transport menggunakan endpointId dan enum PeerConnectionStatus tersendiri
      final physicalPeer = DiscoveredPeer(
        endpointId: 'nearby-endpoint-abc',
        endpointName: 'Galaxy S23',
        serviceId: 'com.siagamesh.emergency.mesh',
        discoveredAt: DateTime.now(),
        status: PeerConnectionStatus.disconnected,
      );

      expect(physicalPeer.endpointId, isNot(equals(mockNode.id)));
      expect(
        physicalPeer.status,
        isNot(equals(PeerConnectionStatus.connected)),
      );
      // Transport tidak memiliki physical peer terkoneksi secara default
      expect(transport.connectedPeers.isEmpty, isTrue);
    });
  });
}
