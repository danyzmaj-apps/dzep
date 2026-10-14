# Džep for iPhone and Android

The phone app: Todos, Ideas, Notes, Ask and Terminal, pairing with a server by scanning the Mac's code. Phones don't set up servers.

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/dzep_core`](../../packages/dzep_core/)) |
| `ios/` | Runner (native channel, push, Live Activities), `DzepWidget` (widgets and the Live Activity), `DzepPush` (decrypts pushes) |
| `android/` | `MainActivity` (native channel), FCM service, reminders, the ongoing omp notification, Todos and New idea widgets |
| `maestro/` | iOS simulator flows |

The two platforms do the same things. Android push needs `android/app/google-services.json` (not committed); without it the app works and keeps reminders local.

Run it from this directory:

```sh
fvm flutter run -d <device>
```

See [docs/BUILDING.md](../../docs/BUILDING.md) and [docs/RELEASING.md](../../docs/RELEASING.md).
