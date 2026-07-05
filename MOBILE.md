# MORR ERP — Mobile

## Option 1 — Install as a PWA (works today, no build needed)

MORR ERP ships a web-app manifest and an offline service worker, so it installs
directly from the browser:

- **Android (Chrome):** open the site → ⋮ menu → **Add to Home screen** → Install
- **iOS (Safari):** open the site → Share → **Add to Home Screen**
- **Desktop (Chrome/Edge):** install icon in the address bar

The installed app runs full-screen with the MORR icon and works offline for
cached modules.

## Option 2 — Native app via Capacitor (App Store / Play Store)

Requires a machine with Android Studio (Android) and/or Xcode (iOS).

```bash
npm install @capacitor/core @capacitor/cli
mkdir -p www && cp nexcore-standalone.html www/index.html
cp manifest.json www/ && cp -r icons www/
npx cap add android    # and/or: npx cap add ios
npx cap sync
npx cap open android   # builds in Android Studio → generate signed APK/AAB
```

`capacitor.config.json` in this repo is pre-configured with app id
`za.co.morr.erp`. The single-file architecture means there is no build step —
the HTML file IS the app. Push-notification and biometric plugins can be added
with `npm i @capacitor/push-notifications @capacitor-community/biometric-auth`.
