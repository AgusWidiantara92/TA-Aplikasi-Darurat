/// Model data pesan bertipe untuk protokol replikasi gossip BlockDAG SiagaMesh (DAG-Sync).
///
/// Mengimplementasikan seluruh tipe pesan sesuai spesifikasi teknis Stage 5E.4.1:
/// - [DAG_HELLO] (Handshake & ringkasan ledger)
/// - [DAG_INV] (Inventaris hash ujung DAG)
/// - [DAG_GET_BLOCKS] (Permintaan pengiriman blok)
/// - [DAG_BLOCK_BATCH] (Pengiriman kumpulan blok audit)
/// - [DAG_SYNC_ACK] (Konfirmasi penerimaan blok)
/// - [DAG_REJECT] (Notifikasi penolakan & kode kesalahan protokol)
/// - [DAG_PRUNED_NOTICE] (Pemberitahuan blok terpangkas pada checkpoint)
///
/// Serialisasi menggunakan format deterministik SACJ-v1 (Application Canonical JSON)
/// dan kompatibel penuh dengan byte array [Uint8List] pada [MeshTransport].
library;

import 'dart:convert';
import 'dart:typed_data';

import '../blockchain_types.dart';
import 'gossip_constants.dart';

/// Jenis pesan resmi dalam protokol replikasi gossip SiagaMesh DAG-Sync.
enum DagGossipMessageType {
  hello('DAG_HELLO'),
  inv('DAG_INV'),
  getBlocks('DAG_GET_BLOCKS'),
  blockBatch('DAG_BLOCK_BATCH'),
  syncAck('DAG_SYNC_ACK'),
  reject('DAG_REJECT'),
  prunedNotice('DAG_PRUNED_NOTICE');

  final String wireName;
  const DagGossipMessageType(this.wireName);

  static DagGossipMessageType? fromWireName(String name) {
    for (final val in values) {
      if (val.wireName == name) return val;
    }
    return null;
  }
}

/// Kontrak dasar abstrak untuk seluruh pesan protokol replikasi gossip BlockDAG.
abstract class DagGossipMessage {
  /// Nama protokol eksplisit (selalu [kDagGossipProtocolName]).
  String get protocol => kDagGossipProtocolName;

  /// Versi protokol eksplisit (selalu [kDagGossipProtocolVersion]).
  int get version => kDagGossipProtocolVersion;

  /// Jenis pesan gossip.
  DagGossipMessageType get type;

  /// Nama discriminator jenis pesan pada payload wire.
  String get typeName => type.wireName;

  /// Identitas node pengirim pesan (*self-claimed technical ID*).
  String get senderNodeId;

  /// Serialisasi model ke bentuk Map kanonikal.
  Map<String, dynamic> toMap();

  /// Serialisasi model ke bentuk string JSON kanonikal deterministik (SACJ-v1).
  String toCanonicalJson() => canonicalJsonEncode(toMap());

  /// Mengonversi pesan menjadi byte array UTF-8 kanonikal siap kirim via [MeshTransport].
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toCanonicalJson()));
}

/// Pesan [DAG_HELLO]: Pengenalan awal status ledger antartetangga 1-hop.
///
/// PERINGATAN METODOLOGIS:
/// Kesamaan [tipHashes] saja TIDAK MEMBUKTIKAN bahwa seluruh riwayat historis ledger
/// identik (misal jika salah satu node telah melakukan pruning blok masa lalu).
/// Oleh karena itu pesan ini juga membawa [schemaVersion], [activeBlocksCount],
/// [maxIndex], dan [genesisHash] sebagai indikator kelengkapan status.
class DagHelloMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final int senderTimestamp;
  final int schemaVersion;
  final int activeBlocksCount;
  final int maxIndex;
  final List<String> tipHashes;
  final String genesisHash;

  @override
  DagGossipMessageType get type => DagGossipMessageType.hello;

  DagHelloMessage({
    required this.senderNodeId,
    required this.senderTimestamp,
    required this.schemaVersion,
    required this.activeBlocksCount,
    required this.maxIndex,
    required List<String> tipHashes,
    required this.genesisHash,
  }) : tipHashes = List.unmodifiable(tipHashes);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'senderTimestamp': senderTimestamp,
    'schemaVersion': schemaVersion,
    'activeBlocksCount': activeBlocksCount,
    'maxIndex': maxIndex,
    'tipHashes': tipHashes,
    'genesisHash': genesisHash,
  };
}

/// Pesan [DAG_INV]: Pengumuman inventaris hash blok terbaru / ujung DAG.
class DagInvMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final int senderTimestamp;
  final List<String> tipHashes;
  final List<String> recentBlockHashes;

  @override
  DagGossipMessageType get type => DagGossipMessageType.inv;

  DagInvMessage({
    required this.senderNodeId,
    required this.senderTimestamp,
    required List<String> tipHashes,
    List<String> recentBlockHashes = const [],
  }) : tipHashes = List.unmodifiable(tipHashes),
       recentBlockHashes = List.unmodifiable(recentBlockHashes);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'senderTimestamp': senderTimestamp,
    'tipHashes': tipHashes,
    'recentBlockHashes': recentBlockHashes,
  };
}

/// Pesan [DAG_GET_BLOCKS]: Permintaan blok spesifik berdasarkan daftar hash (maksimal 4).
class DagGetBlocksMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final String requestId;
  final List<String> requestedBlockHashes;

  @override
  DagGossipMessageType get type => DagGossipMessageType.getBlocks;

  DagGetBlocksMessage({
    required this.senderNodeId,
    required this.requestId,
    required List<String> requestedBlockHashes,
  }) : requestedBlockHashes = List.unmodifiable(requestedBlockHashes);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'requestId': requestId,
    'requestedBlockHashes': requestedBlockHashes,
  };
}

/// Pesan [DAG_BLOCK_BATCH]: Pengiriman kumpulan blok audit aktual (maksimal 4 blok / 16 KiB).
class DagBlockBatchMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final String requestId;
  final int batchIndex;
  final int totalBatches;
  final List<SecurityBlock> blocks;

  @override
  DagGossipMessageType get type => DagGossipMessageType.blockBatch;

  DagBlockBatchMessage({
    required this.senderNodeId,
    required this.requestId,
    required this.batchIndex,
    required this.totalBatches,
    required List<SecurityBlock> blocks,
  }) : blocks = List.unmodifiable(blocks);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'requestId': requestId,
    'batchIndex': batchIndex,
    'totalBatches': totalBatches,
    'blocks': blocks.map((b) => b.toMap()).toList(),
  };
}

/// Pesan [DAG_SYNC_ACK]: Konfirmasi penerimaan dan validasi blok ke ledger lokal peminta.
class DagSyncAckMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final String requestId;
  final List<String> acceptedBlockHashes;
  final List<String> newTipHashes;

  @override
  DagGossipMessageType get type => DagGossipMessageType.syncAck;

  DagSyncAckMessage({
    required this.senderNodeId,
    required this.requestId,
    required List<String> acceptedBlockHashes,
    required List<String> newTipHashes,
  }) : acceptedBlockHashes = List.unmodifiable(acceptedBlockHashes),
       newTipHashes = List.unmodifiable(newTipHashes);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'requestId': requestId,
    'acceptedBlockHashes': acceptedBlockHashes,
    'newTipHashes': newTipHashes,
  };
}

/// Pesan [DAG_REJECT]: Notifikasi penolakan blok atau kesalahan protokol gossip.
class DagRejectMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final String? requestId;
  final String? rejectedHash;
  final String errorCode;
  final String errorMessage;

  @override
  DagGossipMessageType get type => DagGossipMessageType.reject;

  DagRejectMessage({
    required this.senderNodeId,
    this.requestId,
    this.rejectedHash,
    required this.errorCode,
    required this.errorMessage,
  });

  @override
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'protocol': protocol,
      'version': version,
      'type': typeName,
      'senderNodeId': senderNodeId,
      'errorCode': errorCode,
      'errorMessage': errorMessage,
    };
    if (requestId != null) map['requestId'] = requestId;
    if (rejectedHash != null) map['rejectedHash'] = rejectedHash;
    return map;
  }
}

/// Pesan [DAG_PRUNED_NOTICE]: Pemberitahuan bahwa blok yang diminta telah dipangkas.
class DagPrunedNoticeMessage extends DagGossipMessage {
  @override
  final String senderNodeId;
  final String requestId;
  final List<String> prunedBlockHashes;
  final int lastPrunedIndex;
  final String retainedGenesisHash;

  @override
  DagGossipMessageType get type => DagGossipMessageType.prunedNotice;

  DagPrunedNoticeMessage({
    required this.senderNodeId,
    required this.requestId,
    required List<String> prunedBlockHashes,
    required this.lastPrunedIndex,
    required this.retainedGenesisHash,
  }) : prunedBlockHashes = List.unmodifiable(prunedBlockHashes);

  @override
  Map<String, dynamic> toMap() => {
    'protocol': protocol,
    'version': version,
    'type': typeName,
    'senderNodeId': senderNodeId,
    'requestId': requestId,
    'prunedBlockHashes': prunedBlockHashes,
    'lastPrunedIndex': lastPrunedIndex,
    'retainedGenesisHash': retainedGenesisHash,
  };
}
