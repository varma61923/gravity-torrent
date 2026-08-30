# E2E Test Infra: gravity-torrent

## Test Philosophy
- Requirement-driven, opaque-box testing covering specifications (BEP 0003, BEP 0010, BEP 0012, BEP 0023, BEP 0027, RFC 9110), engine RPC contracts, model bounds, security boundaries, and UI logic.
- Methodology: Category-Partition + Boundary Value Analysis (BVA) + Pairwise Combinatorial Testing + Real-World Workload Testing.

## Feature Inventory & Test Coverage Matrix
| # | Feature | Requirement / Spec | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---------|-------------------|:------:|:------:|:------:|:------:|
| 1 | Bencode Encoding & Decoding | BEP 0003: int, str, bytes, list, dict | 5 | 5 | ✓ | ✓ |
| 2 | Metainfo Pre-Add Inspection | BEP 0003: single-file, multi-file, info_hash | 5 | 5 | ✓ | ✓ |
| 3 | Transmission Model & Bitfields | Large swarms, clamped bounds, bit unpacking | 5 | 5 | ✓ | ✓ |
| 4 | Static Analysis & Lint Quality | Zero flutter analyze issues | 5 | 5 | ✓ | ✓ |
| 5 | Blocklist & SSRF Protections | RFC IP ranges, loopback/private/bcast filtering | 5 | 5 | ✓ | ✓ |
| 6 | Settings & Port Validation | Peer port bounds 1..65535, invalid inputs | 5 | 5 | ✓ | ✓ |
| 7 | Multi-Tracker Tiers & Creation | BEP 0012 announce-list, BEP 0027 private flag | 5 | 5 | ✓ | ✓ |
| 8 | Seed Ratio Automation | Ratio calculation, partial downloads, initial seeds | 5 | 5 | ✓ | ✓ |
| 9 | Search Engine Parsing | HTML / regex parsing, title, size, seeds/leeches | 5 | 5 | ✓ | ✓ |
| 10 | Streaming Server & Moov Booster | RFC 9110 Range headers, 206 Partial, 416 OOB | 5 | 5 | ✓ | ✓ |
| 11 | Archive Auto-Extract & Zip-Slip | Symlinks, path traversal, decompression isolates | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **Environment**: Flutter 3.44.8 / Dart 3.12.2 at `/tmp/flutter/bin/flutter` and `/tmp/flutter/bin/dart`.
- **Runner Command**: `/tmp/flutter/bin/flutter test`
- **L10n Command**: `/tmp/flutter/bin/flutter gen-l10n`
- **Analysis Command**: `/tmp/flutter/bin/flutter analyze`

## Coverage Thresholds
- **Tier 1 (Feature Coverage)**: ≥5 test cases per feature (happy-path isolations)
- **Tier 2 (Boundary & Corner Cases)**: ≥5 test cases per feature (limits, malformed data, overflow, edge cases)
- **Tier 3 (Cross-Feature Combinations)**: Pairwise integration across Bencode, Storage, Streaming, Quota, and Engine Models
- **Tier 4 (Real-World Scenarios)**: Realistic end-to-end user workflows
