# Changelog

## 0.2.0

- **Note window** (Mac): a note in a small window of its own, floating over everything (a video, a full-screen app), moved and resized as you like. Open it from a note's header in the main window, which steps aside until you close it and then comes back on that note, or with ⌘P in the popup's Note mode, which takes the note you were writing (or starts a new one) and leaves the app closed when you're done.
- **Smaller main window** (Mac): it now goes down to 480×360; when narrow, the sidebar folds into icons and the list gets narrower before the note does.
- Fixed, Mac popup: opened with the shortcut, its field had no cursor until you pressed a mode key or clicked it; and a draft coming back (Ask, Note, a description) was selected whole, so the next key wiped it.
- Fixed, Mac popup: ⌘O opens the app on the popup's list (Ideas, Todos, Notes, Ask) instead of wherever the app last was.
- Fixed, Mac: ⌘, (Settings), File → Close Window and Džep → Check for Updates… were missing from the menu bar.
- **omp on the Lock Screen**: an omp session you prompt from the iPhone (or follow with the lock-clock button in its top bar) becomes a Live Activity on the Lock Screen and in the Dynamic Island, showing Working with a timer, Needs you (question, approval or plan review), Finished, or Ended, and kept current by push while Džep is closed. A tap opens the session. These pushes carry only that state, never the session's title or text. **Backend:** apply the new `activity_tokens` migration and redeploy `push`; the publisher redeploys `relay`.
- **omp sessions on the iPhone, made for the phone**: the Terminal tab now shows each omp session as a conversation the phone lays out itself, so a narrow kitty window on the Mac no longer means a narrow screen on the iPhone. Answers stream in as Markdown, tool calls are cards with their output, and you can prompt (with images), steer or queue while omp works, stop it, answer its questions and tool approvals, and page back through older messages. Needs the new omp extension [integrations/omp/live.ts](integrations/omp/live.ts) next to `idea.ts`.
- **omp's slash commands from the iPhone**: typing `/` in an omp session's composer suggests omp's commands (its own, plus your extensions', prompts' and skills') with their descriptions, like omp's terminal; a tap (or Tab on a keyboard) fills one in. Commands run in the session's kitty window, so a session without one says so. Update the omp extension ([integrations/omp/live.ts](integrations/omp/live.ts)).
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
- Fixed, Mac popup: a key typed right after ⌘1–⌘4 (or reopening the popup) could select the whole draft, so the next key wiped it; characters typed right after the shortcut were lost in Ask; a click on the list, the hint bar or the padding left no field focused, so Esc and typing did nothing until the field was clicked; ⌘W did nothing. The popup's keys now work whatever was clicked, typing goes into the field at its caret, and ⌘W hides it like Esc.
- Fixed, Mac: closing the popup with the shortcut while the main window was in front handed the keyboard to the app used before; it now stays with the main window, as it did after Esc. And whatever you were typing in there (a note, a description, the search) has the cursor again, instead of typing going nowhere until you clicked it.
- **Main window keys**: ⌘N new item, ⌘F or / search, ↑/↓ move through the list, ⌫ deletes the selected item (with Undo), Esc clears the search or leaves a field for the list. They work whatever was clicked last, also after a click beside a field. Settings (⌘,) takes the keyboard even from a focused field, so Esc closes it.
- Fixed, Mac: selecting several lines of a note or description highlighted whole rows out to the widest line, empty lines included; it now covers just the text.
- Mac: key hints use the system font, so ⌘O no longer reads as ⌘0.
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
