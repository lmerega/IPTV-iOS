# IPTV-iOS — POC-001

A private SwiftUI iPhone/iPad feasibility project (iOS 18+). **No IPTV content or credentials are included.**

## Scope delivered in first build

- Native SwiftUI shell and AVKit/AVPlayer test screen for a user-provided HTTP(S) HLS URL.
- Optional Tailscale setting (informational only): uses the official Tailscale app and existing iOS VPN routes; this app does **not** start a VPN.
- AirPlay permitted by AVPlayer where supported by the stream and target device.
- GitHub Actions unsigned IPA build using macOS and XcodeGen.

**Not implemented yet:** Xtream API login, playlist parser, EPG, catch-up, DVR, proper network diagnostics or a secure persistent account store. Do not confuse the current URL player with those promised later phases.

## GitHub Actions

Open **Actions → Build unsigned iOS IPA**, run it manually or push changes to `main`. A macOS-15 runner runs XcodeGen and `xcodebuild`, then zips `Payload/IPTVPOC.app` into `IPTVPOC-unsigned.ipa`. The run's **Artifacts** section contains the unsigned IPA in a ZIP archive.

GitHub Actions **can run in private repositories**, but macOS jobs consume private-repository billing minutes at the macOS multiplier. Check usage/spending limits in GitHub billing. Do not switch the repository to public to solve a billing error without reviewing the consequences.

## Install without a Mac

The IPA is **unsigned**. It will not install just by tapping it. On Windows, use Sideloadly to sign with your **own** Apple ID (never share the ID/password with maintainers or place them in GitHub). Free Apple provisioning is limited and typically expires after 7 days. Some signing capabilities are restricted without a paid Apple Developer membership. Installation needs a real-device test.

## Testing

1. Install IPA via Windows.
2. Test a public, legitimately accessible HLS URL.
3. With official Tailscale connected, test your private HTTP(S) endpoint.
4. Compare a public server with VPN enabled/disabled.
5. Report audio/video, seek and AirPlay outcomes. Do not post private source URLs or credentials in GitHub issues.

## Privacy note

The entered URL is persisted by `AppStorage` on device for testing convenience. **Do not enter production credentials embedded in URLs**: the POC has not yet implemented Keychain storage. A later iteration will use Keychain for secrets.

## Future milestones

- Secure Xtream credentials and M3U parser
- EPG and native catch-up compatibility testing
- DVR while the app is active, with bounded disk storage
- iPad layout polish and AirPlay tests
