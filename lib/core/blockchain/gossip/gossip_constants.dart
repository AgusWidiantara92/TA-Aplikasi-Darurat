/// Konstanta dan batas ukuran untuk protokol replikasi gossip BlockDAG SiagaMesh (DAG-Sync).
///
/// Mengacu pada dokumen perancangan: `docs/blockdag_gossip_protocol_design_stage_5e4_1.md`.
/// Seluruh batas ukuran dan parameter numerik didefinisikan sebagai konstanta teruji
/// untuk mencegah penyebaran *magic numbers* dan mempermudah pengujian batas (*boundary tests*).
library;

/// Nama pengenal resmi protokol replikasi gossip SiagaMesh.
const String kDagGossipProtocolName = 'SIAGAMESH_DAG_SYNC';

/// Versi protokol replikasi gossip saat ini.
const int kDagGossipProtocolVersion = 1;

/// Batas absolut ukuran byte mentah yang diterima dari transport nirkabel (32 KiB).
/// Payload yang melampaui batas ini langsung ditolak sebelum parsing JSON untuk mencegah
/// serangan *memory exhaustion* / DoS pada perangkat seluler.
const int kMaxRawGossipPayloadBytes = 32768; // 32 KiB

/// Batas maksimum ukuran byte paket serialisasi untuk pesan [DAG_BLOCK_BATCH] (16 KiB).
/// Menjaga agar transfer sekumpulan blok tidak memonopoli kanal radio Nearby Connections.
const int kMaxBatchPayloadBytes = 16384; // 16 KiB

/// Batas maksimum jumlah hash blok yang dapat diminta dalam satu pesan [DAG_GET_BLOCKS].
const int kMaxGetBlocksHashes = 4;

/// Batas maksimum jumlah hash inventaris dalam satu pesan [DAG_INV].
const int kMaxInvHashes = 32;

/// Batas maksimum jumlah hash ujung DAG (*tips*) dalam pesan [DAG_HELLO] dan [DAG_INV].
const int kMaxTipHashes = 16;

/// Batas maksimum jumlah blok yang dapat dimuat dalam satu pesan [DAG_BLOCK_BATCH].
const int kMaxBlocksPerBatch = 4;

/// Batas maksimum jumlah blok yatim (*orphan blocks*) yang dapat ditahan dalam pool sementara (Stage 5E.4.5).
const int kMaxOrphanBlocks = 20;

/// Batas waktu retensi blok yatim (*orphan block TTL*) sebelum kedaluwarsa (60 detik).
const Duration kOrphanBlockTtl = Duration(seconds: 60);

/// Batas maksimum blok yatim yang dapat ditahan dari satu peer tertentu.
const int kMaxOrphansPerPeer = 8;

/// Batas maksimum panjang karakter untuk identifier (NodeId, RequestId).
const int kMaxIdentifierLength = 64;

/// Interval waktu dasar rekonsiliasi inventaris periodik (Stage 5E.4.6).
/// Nilai awal 30 detik merupakan parameter eksperimen yang dapat dikonfigurasi.
const Duration kDefaultPeriodicGossipInterval = Duration(seconds: 30);

/// Batas minimum jeda backoff setelah kegagalan rekonsiliasi (5 detik).
const Duration kMinPeriodicGossipBackoff = Duration(seconds: 5);

/// Batas maksimum jeda backoff setelah kegagalan berulang (120 detik / 2 menit).
const Duration kMaxPeriodicGossipBackoff = Duration(seconds: 120);

/// Rentang default jitter acak untuk mencegah sinkronisasi serentak antarsesama peer (0 - 5 detik).
const Duration kDefaultPeriodicGossipJitterRange = Duration(seconds: 5);

/// Batas waktu kedaluwarsa permintaan blok aktif (in-flight request timeout) sebelum dianggap tidak merespons (15 detik).
const Duration kGossipRequestTimeout = Duration(seconds: 15);

/// Batas waktu kedaluwarsa respons peer terhadap rekonsiliasi inventaris periodik (Stage 5E.4.6.1).
/// Peer yang tidak mengirim respons inventaris valid dalam 15 detik dianggap tidak merespons (unresponsive peer).
const Duration kPeriodicGossipResponseTimeout = Duration(seconds: 15);

/// Batas maksimum panjang karakter untuk pesan deskripsi alasan teknis (*reason*).
/// Mencegah penyisipan teks bebas panjang yang dapat melanggar privasi korban/pengguna.
const int kMaxMetadataReasonLength = 128;

/// Batas maksimum panjang karakter untuk pesan kesalahan (*error message*).
const int kMaxErrorMessageLength = 256;

/// Pola regular expression untuk validasi format hash SHA-256 (64 karakter hex huruf kecil).
final RegExp kSha256HexRegex = RegExp(r'^[0-9a-f]{64}$');

/// Kode kesalahan protokol resmi untuk pesan [DAG_REJECT].
abstract class DagRejectCode {
  static const String unsupportedProtocol = 'UNSUPPORTED_PROTOCOL';
  static const String unsupportedVersion = 'UNSUPPORTED_VERSION';
  static const String unsupportedType = 'UNSUPPORTED_TYPE';
  static const String malformedJson = 'MALFORMED_JSON';
  static const String payloadTooLarge = 'PAYLOAD_TOO_LARGE';
  static const String batchPayloadTooLarge = 'BATCH_PAYLOAD_TOO_LARGE';
  static const String invalidFieldType = 'INVALID_FIELD_TYPE';
  static const String missingRequiredField = 'MISSING_REQUIRED_FIELD';
  static const String invalidHashFormat = 'INVALID_HASH_FORMAT';
  static const String duplicateHash = 'DUPLICATE_HASH';
  static const String exceedsHashLimit = 'EXCEEDS_HASH_LIMIT';
  static const String emptyPayload = 'EMPTY_PAYLOAD';
  static const String privacyViolation = 'PRIVACY_VIOLATION';
  static const String invalidBlockStructure = 'INVALID_BLOCK_STRUCTURE';
  static const String invalidMerkleRoot = 'INVALID_MERKLE_ROOT';
  static const String rateLimited = 'RATE_LIMITED';
  static const String incompatibleNetwork = 'INCOMPATIBLE_NETWORK';
}
