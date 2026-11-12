# Roadmap

## MVP Hardware Pass

- Build and install on iPhone through Xcode.
- Confirm Meta AI registration callback works with `raybanhermes://`.
- Confirm Ray-Ban Meta microphone route over Bluetooth HFP; otherwise keep iPhone mic fallback.
- Confirm `Capture from glasses` produces a usable JPEG preview.
- Run an end-to-end ask against the VPS endpoint after backend deployment.

## Backend Deployment

- Done 2026-06-29 inside existing `hermes-glasses.service`.
- Keep rollback backups on VPS:
  - `/opt/hermes-glasses-webapp/server.mjs.bak-20260629T080030Z`
  - `/etc/nginx/sites-enabled/hermes-glasses.conf.bak-20260629T080030Z`

## Hardening

- Add structured request IDs without logging tokens or media.
- Add explicit Hermes stderr redaction if future Hermes output can include sensitive paths.
- Add UI route picker diagnostics for Ray-Ban output audio.
