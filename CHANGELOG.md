# Changelog

## Unreleased

- Quick questions take images: paste with ⌘V or attach with 📎 in the Mac popup and main window, paste or pick from Photos on the iPhone. Up to 4 per question, scaled to 2048 px at most; they show in the chat history on every device.

**Backend:** run `tool/setup-backend.sh` (new migration: `chat_messages.images` and the private `chat` bucket; `ask` redeployed). The model must accept images; `deepseek-flash` (V4.1) does.

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
