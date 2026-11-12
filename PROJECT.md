# Ray-Ban Meta Hermes iOS

## Purpose

Dev-only iOS app and backend bridge for asking Hermes/OpenAI Codex questions with Ray-Ban Meta camera context.

## Stack

- iOS: SwiftUI, Meta Wearables Device Access Toolkit for iOS, Speech, AVFoundation, Keychain.
- Backend: Node.js, Express, multipart upload, Hermes CLI.

## Paths

- iOS app: `ios/CameraAccess.xcodeproj`
- Backend gateway: `backend/`
- Alternative API server snapshot: `deploy/hermes-glasses-webapp/` (web assets are absent).
- Structure and build instructions: `README.md`; current verification and blockers: `STATE.md`.

## Safety

- Hermes APP_TOKEN is not committed. The iOS app stores it in Keychain, and the backend reads `APP_TOKEN` from the environment.
- Both servers use temporary files for uploaded frames and clean them up after processing.
- The GitHub preparation pass does not deploy changes to the existing VPS.
