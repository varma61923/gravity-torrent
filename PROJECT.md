# Project: gravity-torrent

## Architecture
Gravity Torrent is a cross-platform BitTorrent client built with Flutter (Dart) and an embedded `libtransmission` engine linked via `flutter_libtransmission`.
- **UI & Presentation Layer** (`app/lib/screens/`, `app/lib/dialogs/`): Torrents list, details sheets, settings, torrent creation, search, RSS, stats.
- **State & Model Layer** (`app/lib/models/`): `TorrentsModel`, `SessionModel`, `RssFeedsModel`, `SearchModel`, `FavoritesModel`.
- **Engine Abstraction Layer** (`app/lib/engine/`): Abstract `Engine`, `Session`, `Torrent`, `File`, `Tracker`, `Peer` contracts, implemented by `TransmissionEngine` over JSON-RPC.
- **Services Subsystem** (`app/lib/services/`):
  - `Bencode` / `TorrentCreatorService`: BitTorrent metainfo creation, bencoding serialization and decoding.
  - `SearchService`: Torrent search engine querying and result parsing.
  - `RssService`: RSS / Atom feed polling, automated download rules.
  - `StreamingServer` & `SubtitlesServer`: Local HTTP streaming with RFC 9110 byte-range seeking and priority boosting.
  - `BlocklistService`, `BackupService`, `AutoExtractService`, `QuotaService`, `SeedRatioService`.
- **Utilities & Security** (`app/lib/utils/`): `bencode.dart` (BEP 0003), `bitfield.dart`, `ip_address.dart` (SSRF defense), `moov_priority_booster.dart`.

## Feature Inventory
| # | Feature | Description | Milestone | Source | Status |
|---|---------|-------------|-----------|--------|--------|
| 1 | Bencode Encoding & Decoding | Full BEP 0003 bencode encoder and decoder (int, str, binary bytes, list, dict with byte-ordered keys, non-overflowing bounds, depth limit) | M1 | Survey | DONE |
| 2 | Metainfo Pre-Add Parsing | Decode `.torrent` files in Dart to compute exact `predictedSize`, file trees, and info_hash before adding to engine, with disk free space checks | M1 | Survey | DONE |
| 3 | Model Piece Count Scale | Support large swarms without clamping `pieceCount` and bitfield to 1,000,000 | M1 | Survey | DONE |
| 4 | Static Analysis & Lint Cleanliness | Resolve `unawaited_futures` lint in `settings.dart` and enforce clean analyzer output across the entire codebase | M2 | Survey | DONE |
| 5 | Blocklist Offline Resolver | Fix DNS timeout in `blocklist_service_test.dart` for deterministic offline verification | M2 | Survey | DONE |
| 6 | Peer Port Bounds Validation | Enforce port range `1..65535` in `peer_port.dart` settings dialog | M2 | Survey | DONE |
| 7 | BEP 12 Multi-Tracker Tiering | Parse multi-line tracker text into grouped tiers separated by blank lines in `create_torrent_dialog.dart` | M2 | Survey | DONE |
| 8 | Seed Ratio Service Alignment | Reconcile `SeedRatioService` calculation with UI details tab (`uploadedEver / downloadedEver`) | M2 | Survey | DONE |
| 9 | Search Engine Result Parser | Implement HTML / regex result parser in `SearchService._parseResults` for torrent search providers | M3 | Survey | DONE |
| 10 | Streaming & Priority Booster Hardening | Harden `MoovPriorityBooster` speed limit restore and streaming file offset handling | M3 | Survey | DONE |
| 11 | Security & Path Traversal Verification | Verify and harden path sanitization in torrent creation and auto-extract | M3 | Survey | DONE |
| 12 | Comprehensive E2E Test Suite | Build complete multi-tier test suite (Tiers 1-4) covering all features and edge cases | M4 | Survey / E2E Track | DONE |
| 13 | Final Verification, Adversarial Hardening & Git Push | Run 100% test gate, Tier 5 adversarial hardening, commit and push to active branch | M5 | Final Milestone | DONE |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Core Protocol, Models & Bencoding | Dart Bencode decoder/encoder, metainfo pre-add inspection in `add_torrent.dart`, unclamp `pieceCount` | none | DONE |
| M2 | UI Validation, Multi-Tracker Tiers & Seed Ratio | Lint fix in `settings.dart`, mock lookup for `blocklist_service_test.dart`, port validator bounds, BEP 12 tracker tiers, seed ratio calculation | none | DONE |
| M3 | Search Engine Parser & Streaming Hardening | Complete `SearchService._parseResults`, harden `MoovPriorityBooster` speed limits, verify security paths | none | DONE |
| M4 | E2E Testing Suite (Tiers 1-4) | Requirement-driven test suite with test runner and `TEST_READY.md` publication | M1, M2, M3 | DONE |
| M5 | Final Hardening, Gate & Git Push | Pass 100% E2E tests, Tier 5 adversarial hardening, git commit and push to `fix/comprehensive-bug-hunt` | M4 | DONE |

## Interface Contracts
### Bencode Module (`bencode.dart` ↔ `torrent_creator_service.dart`, `add_torrent.dart`)
- `Bencode.encode(Object value) -> Uint8List`: Serializes int, String, Uint8List, List<int>, List, Map (with UTF-8 byte-order key sorting).
- `Bencode.decode(Uint8List bytes) -> Object`: Parses bencoded byte stream into Dart `int`, `Uint8List` (for byte strings), `List<dynamic>`, and `Map<String, dynamic>`.
- `Bencode.decodeTorrent(Uint8List bytes) -> TorrentMetadata`: Returns structured `TorrentMetadata` with `infoHash`, `infoHashHex`, `name`, `totalSize`, `pieceLength`, `pieceCount`, and `files`.

### SeedRatioService (`seed_ratio_service.dart` ↔ `Torrent`)
- Calculates ratio as `torrent.downloadedEver > 0 ? (torrent.uploadedEver / torrent.downloadedEver) : (torrent.size > 0 ? torrent.uploadedEver / torrent.size : 0.0)`.

### SearchService (`search_service.dart` ↔ `SearchResult`)
- `_parseResults(String source, String html) -> List<SearchResult>`: Extracts title, info_hash / magnet link, size bytes, seeders, leechers from HTML response.

## Code Layout
- `app/lib/utils/bencode.dart`: Core Bencode encoder and decoder.
- `app/lib/services/torrent_creator_service.dart`: Torrent creation and SHA-1 hashing.
- `app/lib/dialogs/add_torrent.dart`: Add torrent dialog with metadata pre-inspection.
- `app/lib/engine/transmission/models/torrent.dart`: Engine torrent models.
- `app/lib/screens/settings/settings.dart`: Settings screen.
- `app/lib/screens/settings/dialogs/peer_port.dart`: Port configuration dialog.
- `app/lib/dialogs/create_torrent_dialog.dart`: Torrent creation UI.
- `app/lib/services/seed_ratio_service.dart`: Seed ratio auto-stop service.
- `app/lib/services/search_service.dart`: Search service and parser.
- `app/lib/utils/moov_priority_booster.dart`: Video streaming booster.
- `app/test/`: Comprehensive unit and regression test suite.
