# Windows App Signing Setup Action

Prepare your Windows GitHub Actions environment for **automated code signing** with **Certum's SimplySign** cloud signing service.

This action installs the SimplySign Desktop app, configures required registry keys, performs secure TOTP authentication, and verifies your signing certificate — enabling **fully automated and unattended Windows code signing** in CI.

---

## 🧰 Inputs

| Name | Required | Description |
|------|-----------|-------------|
| `certum-username` | ✅ | Your Certum account username. |
| `certum-otp-uri` | ✅ | The `otpauth://` TOTP URI for your SimplySign account. |
| `certum-key-id` | ✅ | The SHA1 thumbprint of your signing certificate. |
| `simplysign-url` | ❌ | Optional direct URL to download the SimplySign Desktop MSI. |

---

## 🧑‍💻 Example Usage

```yaml
name: Sign Windows App

# Set the URL as an environment variable for the cache key
env:
  SIMPLYSIGN_URL: 'https://files.certum.eu/software/SimplySignDesktop/Windows/9.3.2.67/SimplySignDesktop-9.3.2.67-64-bit-en.msi'

jobs:
  sign:
    runs-on: windows-latest

    steps:
      - name: Checkout source
        uses: actions/checkout@v4

      - name: Cache SimplySign Installer
        uses: actions/cache@v4
        with:
          # This is the path where the installer will be saved by the action
          path: SimplySignDesktop.msi
          # The key ensures we get a new download if the URL changes
          key: simplysign-msi-${{ env.SIMPLYSIGN_URL }}

      - name: Setup Certum SimplySign environment
        uses: dismine/windows-app-signing-setup-action@v1
        with:
          certum-username: ${{ secrets.CERTUM_USERNAME }}
          certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
          certum-key-id: ${{ secrets.CERTUM_KEY_ID }}
          simplysign-url: ${{ env.SIMPLYSIGN_URL }}

      - name: Sign application
        run: |
          & 'C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe' sign `
            /tr http://timestamp.certum.pl `
            /td sha256 `
            /fd sha256 `
            /sha1 $env:CERTUM_KEY_ID `
            'dist\\MyApp.exe'
```

---

## 🔐 Required Secrets

Set these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---------|-------------|
| `CERTUM_USERNAME` | Your Certum SimplySign username (usually email). |
| `CERTUM_OTP_URI` | The TOTP URI for generating OTP codes automatically. |
| `CERTUM_KEY_ID` | The SHA1 thumbprint of the signing certificate. |

---

## 🧾 Outputs

| Variable | Description |
|-----------|-------------|
| `SS_PATH` | Path to the installed SimplySign Desktop directory. |

---

## 🧾 License

MIT License © 2025 — Maintained by dismine

This action is **not affiliated** with Certum.
