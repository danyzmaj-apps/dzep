# Changelog

## Unreleased

- **omp sessions on the iPhone, made for the phone**: the Terminal tab now shows each omp session as a conversation the phone lays out itself, so a narrow kitty window on the Mac no longer means a narrow screen on the iPhone. Answers stream in as Markdown, tool calls are cards with their output, and you can prompt (with images), steer or queue while omp works, stop it, answer its questions and tool approvals, and page back through older messages. Needs the new omp extension [integrations/omp/live.ts](integrations/omp/live.ts) next to `idea.ts`.
- **Terminal opens at once**: the iPhone keeps the last list, conversations and screens, so they show immediately (marked when the Mac isn't answering) and catch up from where they were.
- **Terminal reconnects by itself**: after the Mac slept, the network dropped or the phone came back from the background, the link could stay dead (the Mac looked connected and answered nothing) until Džep was restarted. Both sides now join again on their own, with a fresh sign-in token.
- omp windows that started before the omp extension was installed say so in the Terminal list: restart omp in them (`omp -c` continues the conversation) to see them as conversations.
- Fixed: text typed while the previous prompt was still being sent was wiped when it arrived.
- kitty screens (shells, omp's own menus) arrive as changes instead of whole every second, keep their place while you read, and a shell's long lines wrap to the phone. The Mac talks to kitty over its socket instead of starting `kitten` for every command.
- **Push notifications on the iPhone**: reminders arrive on time even when Džep hasn't been opened since they were set on the Mac, and a todo ticked off elsewhere no longer goes off. When an omp run ends or omp needs you (a question or an approval waiting) while you're away from the Mac, the iPhone gets a push too; a tap opens that session, also when it launches the app, and none comes while the phone is showing that session. Your server encrypts every notification with a key only your iPhone has; the relay that hands it to Apple sees only ciphertext.
- **Setup wizard**: on first launch the Mac app sets up your server for you (Supabase project, tables, GitHub sign-in, functions, AI key) from a Supabase access token. No repo or CLI needed; `tool/setup-backend.sh` still works.
- **iPhone setup by QR**: Mac **Settings → Set up iPhone…** shows a one-time code (10 minutes); the iPhone app scans it with its own camera and signs in, no GitHub login on the phone.
- **New icon**: a pocket with a note in it ("džep" is Croatian for pocket), in the app icons, the Mac menu bar and the app's screens.
- Fixed: on the Mac, Settings could ignore the gear and Done (the main window didn't redraw on app changes).
- Fixed: the popup could crash at launch when it opened in Ask mode before the chats had loaded.
- **Notes**: free-text notes next to ideas and todos, first line as the title, saved as you type. In the popup (⌘3), the main window's Notes, the iPhone's Notes tab, Siri ("add a note to Džep") and omp's `/note`.
- **Simpler popup**: it opens straight into the mode you used last; a strip on top (⌘1–⌘4: Idea, Todo, Note, Ask) replaces the 1/2/3/4 chooser, with **Open app** (⌘5) at its far right.
- **Simpler main window**: the sidebar is Todos, Ideas, Notes, Ask and your projects; done todos fold away under the open ones instead of a separate list.
- Quick questions take images: paste with ⌘V or attach with 📎 in the Mac popup and main window, paste or pick from Photos on the iPhone. Up to 4 per question, scaled to 2048 px at most; they show in the chat history on every device.
- Fixed: right after launch the Mac could join the terminal channel before its sign-in was ready, and then never hear the iPhone (its Terminal tab spun forever).

**Backend:** run `tool/setup-backend.sh` (new migrations: `chat_messages.images` with the private `chat` bucket, the `note` kind, and push: `push_devices`, `push_sent`, `push_config` and a `pg_cron` job; `ask` and `device` redeployed; new `pair` and `push` functions; sign-in links valid for 10 minutes, `otp_expiry = 600`). Images need a model that reads them; `deepseek-flash` (V4.1) does.

## 0.1.0

First public release.

- Self-hosted: on first launch, connect your own Supabase project (setup screen or `dzep://setup` link). `tool/setup-backend.sh` sets one up.
- Quick questions work with any OpenAI-compatible API (`AI_BASE_URL`, `AI_MODEL`, `AI_API_KEY`); DeepSeek stays the default.
- Private servers: after the first account, only allow-listed emails can sign up.
- Delete your account, and everything in it, from Settings.
- The Mac app ships as a notarized DMG and updates itself (Sparkle).
- Fixed: a first sync of more than 1,000 items or chat messages missed the older ones.
- Fixed: an image sent from the iPhone stayed in Storage when the Mac didn't answer.
- iOS privacy manifest; omp `/idea` and `/todo` extension in `integrations/omp`.

**Backend:** run `tool/setup-backend.sh` (new migration, `ask` reads `AI_*` secrets instead of `DEEPSEEK_API_KEY`).
