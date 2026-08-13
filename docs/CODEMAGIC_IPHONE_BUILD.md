# OpenVision iPhone build

OpenVision is built and signed on Codemagic while its source remains editable from Windows.

## Fixed application identity

- Bundle ID: `ca.seedtosausage.openvision`
- URL scheme: `ca-seedtosausage-openvision`
- Distribution: Ad Hoc
- Meta registration: Developer Mode (`META_APP_ID = 0`)

The iPhone must be registered in the Apple Developer account and included in the Ad Hoc provisioning profile. Meta AI must have Developer Mode enabled for the connected glasses.

## One-time account setup

1. Fork `rayl15/OpenVision` to the `ErosEdan` GitHub account.
2. Add the fork to Codemagic as an iOS app that uses `codemagic.yaml`.
3. In App Store Connect, create an API key named `Codemagic` with App Manager access.
4. Add that key to Codemagic under Team integrations → Developer Portal using the integration name `codemagic`.
5. Register the target iPhone's UDID in Apple Developer.
6. Register the explicit App ID `ca.seedtosausage.openvision`.
7. In Codemagic code-signing identities, generate an Apple Distribution certificate and create or fetch an Ad Hoc provisioning profile for the bundle ID containing the iPhone.

## Build

Run the `OpenVision signed iPhone IPA` workflow manually in Codemagic. The resulting `.ipa` appears under build artifacts and can be downloaded on Windows and installed on the registered iPhone.

Pushing a tag matching `build-*`, such as `build-1`, also starts the workflow.

## Glasses registration

1. Pair the glasses normally in Meta AI.
2. Enable Developer Mode in Meta AI under the glasses settings.
3. Install and open OpenVision.
4. Grant the requested iOS permissions.
5. Open OpenVision Settings → Glasses → Register.
6. Approve registration in Meta AI and return to OpenVision.

API keys for OpenAI, Gemini, or another backend are entered inside OpenVision after installation. They are not stored in GitHub or Codemagic.
