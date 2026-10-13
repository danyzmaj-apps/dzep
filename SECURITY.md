# Security

## Reporting

Please report vulnerabilities privately through GitHub's private vulnerability reporting: [Report a vulnerability](https://github.com/danyzmaj-apps/dzep/security/advisories/new) (the repo's **Security** tab). Don't open a public issue. You'll get an answer within a week, and credit in the advisory if you want it.

## Scope

- The apps: Mac (`apps/dzep-macos-app`), iPhone and Android (`apps/dzep-mobile`), and the shared code (`packages/dzep_core`).
- The backend every user deploys: migrations and row-level security, and the `ask`, `device`, `pair` and `push` edge functions (`apps/dzep-macos-app/supabase`).
- The publisher's push relay (`apps/dzep-macos-app/supabase/functions/relay`).
- The Mac's local API and the omp extensions (`apps/dzep-macos-app/integrations/omp`).

Out of scope: Supabase, GitHub, Apple, Google and AI providers themselves; a server whose owner shared their account or allowed someone's sign-up; attacks that need an unlocked device you already control.

Most valuable to hear about: anything that lets one account read or write another's data, reach the terminal bridge, read a push's contents, use the relay to push to devices that aren't the caller's, or run the AI on someone else's server.

## Model

- **No shared server.** Each user runs their own Supabase project. Every table has row-level security that limits a user to their own rows, and the apps hold only the publishable key.
- **Private sign-up.** Closed after the first account (the `before_user_created` hook), except for emails listed in `allowed_signups`.
- **Pairing.** A phone signs in by scanning a one-time code from the Mac (a hashed magic-link token, single use, valid 10 minutes). Phones never set up servers.
- **AI key.** An edge function secret; it never reaches a client.
- **Device tokens.** Siri, the widgets and notification actions authenticate to the `device` function with a random per-device token. The server stores only its SHA-256, and sign-out deletes it.
- **Push encryption.** Each phone makes a 32-byte AES key and gives it only to its own server at registration. The server seals every notification with AES-256-GCM (random 12-byte nonce) and sends `base64(nonce ‖ ciphertext ‖ tag)` to the publisher's relay, which passes it to APNs (iPhone, decrypted by the notification service extension) or FCM (Android, a data-only message decrypted by the app). The relay sees the push token, the kind, a collapse id and ciphertext, and stores nothing. Exception: iPhone Live Activity updates can't be encrypted, so they carry only an omp session's state and a timestamp, never text. The relay's APNs key and Firebase service account are its secrets alone.
- **Local API.** The Mac's API listens on 127.0.0.1 only, behind a random token in `~/.config/dzep/cli.json` (mode 600, in a mode-700 directory). omp's live extension uses the same token for its WebSocket.
- **Terminal from the phone** lets anyone signed in to the account read the Mac's omp sessions and kitty screens, prompt omp, answer its questions and approvals, and type into kitty windows. It is off by default and uses a Realtime channel only that user can join; nothing it carries is stored on the server.
- **Updates.** Mac updates are accepted only when signed with the project's Sparkle EdDSA key, and they arrive notarized. Phone builds come from the App Store and Google Play (Play App Signing).
