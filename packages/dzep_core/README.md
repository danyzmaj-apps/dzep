# dzep_core

Dart and Flutter code shared by the Mac app and the phone app: the connected backend and sign-in (`session.dart`, `backend.dart`, `account.dart`), the offline-first sync store (`store.dart`), quick-question chats (`chat.dart`), reminders (`remind.dart`), the terminal protocol and remote (`live.dart`, `terminal_*.dart`), omp session activities (`live_activity.dart`), the `dzep/native` platform channel (`native.dart`) and shared UI.

Not published to pub.dev; it is a member of the repo's pub workspace. Test it from this directory:

```sh
fvm flutter test
```

See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
