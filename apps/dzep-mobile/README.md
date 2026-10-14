# Džep for iPhone and Android

The phone app: Todos, Ideas, Notes, Ask and Terminal, pairing with a server by scanning the Mac's code. Phones don't set up servers.

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/dzep_core`](../../packages/dzep_core/)) |
| `ios/` | Runner (native channel, push, Live Activities), `DzepWidget` (widgets and the Live Activity), `DzepPush` (decrypts pushes) |
| `android/` | `MainActivity` (native channel), FCM service, reminders, the ongoing notification for followed coding sessions, Todos and New idea widgets |
| `maestro/` | iOS simulator flows |
| `test/screenshots/` | The README's phone screenshots, rendered on made-up data ([BUILDING.md](../../docs/BUILDING.md#screenshots)) |

The two platforms do the same things, push included. Building Android from source, push needs your Firebase project's `android/app/google-services.json` (not committed; [BUILDING.md](../../docs/BUILDING.md#android)); a build without it works and schedules reminders on the phone instead.

Run it from this directory:

```sh
fvm flutter run -d <device>
```

See [docs/BUILDING.md](../../docs/BUILDING.md) and [docs/RELEASING.md](../../docs/RELEASING.md).
