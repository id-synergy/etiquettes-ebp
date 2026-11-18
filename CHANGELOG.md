# Changelog

**Technical** change history of the **Étiquettes EBP** app (for developers).
The **App Store release notes** (user-facing) live separately, in
`fastlane/metadata/<language>/release_notes.txt`.

Format based on [Keep a Changelog](https://keepachangelog.com/). This project adheres to
[SemVer](https://semver.org/). French version: [CHANGELOG.fr.md](CHANGELOG.fr.md).

## [1.1] — 2026-11-18

### Added
- **Device-to-device sharing** gathered in Settings: export label templates and printer settings, together ("Export all") or separately, with a universal import that automatically recognizes what it receives.
- **Multi-page QR sharing** for payloads too large for a single code (useful without AirDrop). Manual page stepping; the receiving device verifies a signature before applying, guaranteeing a complete and intact transfer.
- **Update check on launch**: the app notifies you when a newer version is available on the App Store.

### Changed
- **Smoother scanning**: a code held in front of the camera is no longer re-read in a loop (no more repeated vibration). In multi-scan, an item is added only once; quantity is then adjusted in the batch.
- During a QR transfer, the sheet can no longer be dismissed by an accidental swipe.

### Fixed
- **EAN-13 barcode**: an encoding error prevented some labels from being read by checkout scanners.
- **AirDrop sharing** made reliable for templates and printer settings (the share sheet failed to open in some cases; iPad popover handled).
- **History**: "Resume" and "Restore" now open the correct item, reloaded from the gateway (up-to-date stock, net price, VAT).
- **Orientation**: iPhone is locked to portrait again; iPad keeps all four orientations.

## [1.0] — 2026-11-14

### Added
- First public release. Prints product labels from an EBP gateway.
- Item search, barcode scanning, product details (incl./excl. VAT price, VAT, stock).
- Label templates (presets + custom), format and printer selection (Pocket 5890, Brother, NETUM).
- Batch printing, history of viewed and printed items.
- Offline demo mode (dummy data, simulated printing).

[1.1]: https://github.com/id-synergy/etiquettes-ebp/releases/tag/v1.1
[1.0]: https://github.com/id-synergy/etiquettes-ebp/releases/tag/v1.0
