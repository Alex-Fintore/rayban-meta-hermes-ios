# Ray-Ban Meta Hermes iOS

## Purpose

Experimental iOS companion and backend bridge for asking Hermes questions with Ray-Ban Meta camera context. The public repository is intended for sharing the prototype and reproducing its simulator build.

## Stack

- iOS: SwiftUI, Meta Wearables Device Access Toolkit for iOS, Speech, AVFoundation, Keychain.
- Backend: Node.js, Express, multipart upload, Hermes CLI.

## Paths

- iOS app: `ios/CameraAccess.xcodeproj`
- Backend gateway: `backend/`
- Alternative API server snapshot: `deploy/hermes-glasses-webapp/` (web assets are absent).
- Structure and build instructions: `README.md`; current verification and blockers: `STATE.md`.
- Repository cover and social preview: `docs/assets/cover.jpg` (1280 × 640; generated concept illustration).

## Safety

- Hermes APP_TOKEN is not committed. The iOS app stores it in Keychain, and the backend reads `APP_TOKEN` from the environment.
- Both servers use temporary files for uploaded frames and clean them up after processing.
- The GitHub preparation pass does not deploy changes to the existing VPS.
- New installations start without a server URL; configure your own HTTPS gateway and signing team.
