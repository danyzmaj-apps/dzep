# Privacy policy

*Applies to the Džep apps for Mac, iPhone and Android published by Danijel Lovric ("the publisher"). Last updated 13 October 2026.*

Short version: the publisher runs no Džep cloud and never receives what you write in Džep. Your data goes to a server you own. The only thing the publisher operates is a relay that forwards encrypted push notifications to Apple and Google.

## Where your data lives

Džep stores your ideas, todos, notes, quick questions and their answers, attached images, and your account (GitHub user name, avatar URL, email) in a [Supabase](https://supabase.com) project that **you** create and own. The Mac app's setup wizard creates it in your Supabase account. Each app connects only to the server it was set up or paired with. The publisher has no access to it.

What happens to that data on your server is up to you and Supabase's terms. You can delete your account and everything in it from Settings in any Džep app; images you attached are deleted from your server's storage first.

## What the apps send, and to whom

- **To your server:** everything you save, so your devices stay in sync; the name of the device something was added on (e.g. "Danijel's MacBook Pro"); and, for push notifications, the phone's push token and a key the phone generated (below).
- **To GitHub:** when you sign in with GitHub on the Mac, GitHub's usual sign-in exchange. Phones never sign in to GitHub: they sign in with a code from your Mac, which your server checks (it keeps only a hash of the code).
- **To your AI provider:** only if you set up Ask. Your questions, the recent turns of that chat and attached images go from **your server** to the OpenAI-compatible provider you chose, with your key. The apps never contact the provider themselves.
- **To the publisher's push relay** (phones only, when push is on):
  - Every notification is encrypted on your server with an AES-256 key that only your phone and your server know. The relay receives the phone's push token, the kind of notification (reminder, terminal, or session state), a collapse id (a todo id or an omp session key) and the ciphertext.
  - It can't read titles, todo text or terminal output. It forwards the message to Apple (APNs) or Google (Firebase Cloud Messaging) and stores nothing.
  - One exception, on iPhone: iOS shows Live Activity updates without running the app's code, so those can't be encrypted. For them the relay and Apple see the session's state (working, needs you, finished, ended) and since when, nothing else. Session titles and project names never travel through a push.
  - The relay runs on Supabase, whose platform keeps short-lived request logs (time, status, errors). The relay doesn't log tokens or message contents.
- **To Apple or Google:** push notifications are delivered by APNs (iPhone) or Firebase Cloud Messaging (Android), under their own privacy terms. The Android app includes Firebase Cloud Messaging only to receive these encrypted messages. It includes no Firebase Analytics or Crashlytics.
- **Updates (Mac):** the Mac app checks GitHub Releases for new versions (Sparkle). That request carries your IP address and the app version, as any download does.

The apps contain no analytics, advertising or tracking SDKs, and the publisher doesn't sell or share data, because it doesn't have any.

## Permissions

- **Camera** (phones): only to scan the setup code the Mac shows. Images from the camera aren't stored or sent.
- **Photos / files**: only the images you pick to attach to a question, uploaded to your server.
- **Notifications**: reminders, terminal alerts and followed omp sessions.
- **Alarms & reminders** (Android): to deliver reminders on time.
- **Terminal from phone** (Mac, off by default): when you turn it on, the Mac lets phones signed in to your account see and type into your omp and kitty windows over your server's Realtime channel. Nothing it carries is stored.

## Children

Džep is not directed at children under 13.

## Changes

Changes to this policy are made in this file; its history is public at [github.com/danyzmaj-apps/dzep](https://github.com/danyzmaj-apps/dzep/commits/main/docs/PRIVACY.md).

## Contact

Questions: open an issue at [github.com/danyzmaj-apps/dzep/issues](https://github.com/danyzmaj-apps/dzep/issues). Security reports: see [SECURITY.md](../SECURITY.md).
