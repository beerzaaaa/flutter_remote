# FileBeam

**Wireless File Transfer over Local Wi-Fi**

FileBeam turns your Android phone into a local file server — accessible from any browser on the same Wi-Fi network. No cables, no cloud, no account required.

---

## Features

- **Browse & Download** — navigate your phone's storage and download files directly from a browser
- **Upload Files** — drag & drop or select multiple files to upload from any device
- **QR Code** — instant connection via QR scan, no typing required
- **Background Service** — server keeps running while the app is minimized
- **Range / Partial Content** — supports resumable downloads and in-browser media playback

---

## How It Works

1. Open FileBeam on your Android phone
2. Make sure both your phone and computer are on the same Wi-Fi network
3. Tap **Start** — the app displays a QR code and URL (e.g. `http://192.168.x.x:3000`)
4. Scan the QR code or open the URL in any browser
5. Browse, upload, and download files freely

---

## Requirements

- Android 6.0+ (API 23)
- Wi-Fi connection
- Storage permission (All Files Access) required on Android 11+

---

## Tech Stack

| Layer | Library |
|---|---|
| HTTP Server | [shelf](https://pub.dev/packages/shelf) + shelf_static + shelf_multipart |
| Background | [flutter_background_service](https://pub.dev/packages/flutter_background_service) |
| Network | [network_info_plus](https://pub.dev/packages/network_info_plus) |
| QR Code | [qr_flutter](https://pub.dev/packages/qr_flutter) |
| Ads | [google_mobile_ads](https://pub.dev/packages/google_mobile_ads) |

---

## Build

```bash
# Debug
flutter run

# Release (App Bundle for Play Store)
flutter build appbundle --release
```

> **Note:** Before publishing, replace the test AdMob IDs in `lib/main.dart` and `AndroidManifest.xml` with your real IDs from the [AdMob Console](https://admob.google.com).

---

## License

MIT

