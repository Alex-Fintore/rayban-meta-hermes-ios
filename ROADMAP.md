# Roadmap

## MVP Hardware Pass

- Build and install on iPhone through Xcode.
- Confirm Meta AI registration callback works with `raybanhermes://`.
- Confirm Ray-Ban Meta microphone route over Bluetooth HFP; otherwise keep iPhone mic fallback.
- Confirm `Capture from glasses` produces a usable JPEG preview.
- Run an end-to-end ask against the VPS endpoint after backend deployment.

## Reproducible Setup

- Keep the simulator build reproducible through GitHub Actions.
- Validate a complete setup against a developer's own HTTPS gateway.
- Document the minimum Hermes CLI configuration needed for text and image requests.

## Hardening

- Add structured request IDs without logging tokens or media.
- Add explicit Hermes stderr redaction if future Hermes output can include sensitive paths.
- Add UI route picker diagnostics for Ray-Ban output audio.
