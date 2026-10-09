# Changelog

## Unreleased

- **Setup wizard**: on first launch the Mac app sets up your server for you (Supabase project, tables, GitHub sign-in, functions, AI key) from a Supabase access token. No repo or CLI needed; `tool/setup-backend.sh` still works.
- **iPhone setup by QR**: Mac **Settings → Set up iPhone…** shows a one-time code (10 minutes); the iPhone app scans it with its own camera and signs in, no GitHub login on the phone.
- **New icon**: a pocket with a note in it ("džep" is Croatian for pocket), in the app icons, the Mac menu bar and the app's screens.
- Fixed: on the Mac, Settings could ignore the gear and Done (the main window didn't redraw on app changes).
- Fixed: the popup could crash at launch when it opened in Ask mode before the chats had loaded.
- **Notes**: free-text notes next to ideas and todos, first line as the title, saved as you type. In the popup (⌘3), the main window's Notes, the iPhone's Notes tab, Siri ("add a note to Džep") and omp's `/note`.
- **Simpler popup**: it opens straight into the mode you used last; a strip on top (⌘1–⌘4: Idea, Todo, Note, Ask) replaces the 1/2/3/4 chooser.
- **Simpler main window**: the sidebar is Todos, Ideas, Notes, Ask and your projects; done todos fold away under the open ones instead of a separate list.
- Quick questions take images: paste with ⌘V or attach with 📎 in the Mac popup and main window, paste or pick from Photos on the iPhone. Up to 4 per question, scaled to 2048 px at most; they show in the chat history on every device.
- Fixed: right after launch the Mac could join the terminal channel before its sign-in was ready, and then never hear the iPhone (its Terminal tab spun forever).

**Backend:** run `tool/setup-backend.sh` (new migrations: `chat_messages.images` with the private `chat` bucket, and the `note` kind; `ask` and `device` redeployed; new `pair` function; sign-in links valid for 10 minutes, `otp_expiry = 600`). Images need a model that reads them; `deepseek-flash` (V4.1) does.

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
