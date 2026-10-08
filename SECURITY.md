# Security

Please report vulnerabilities privately through [GitHub's security advisories](https://github.com/danyzmaj-apps/dzep/security/advisories/new), not in public issues. You'll get an answer within a week.

## Model

- Each user runs their own Supabase project; there is no shared server. Every table has row-level security that limits a user to their own rows, and the apps hold only the publishable key.
- Sign-up is closed after the first account (the `before_user_created` hook), except for emails listed in `allowed_signups`.
- The AI key is an edge function secret and never reaches a client.
- Siri, the widgets and reminder actions authenticate to the `device` function with a random per-device token. The server stores only its SHA-256, and sign-out deletes it.
- The Mac's local API listens on 127.0.0.1 only, behind a random token in `~/.config/dzep/cli.json` (mode 600, in a mode-700 directory).
- **Terminal from iPhone** lets anyone signed in to the account type into the Mac's kitty windows. It is off by default, and it uses a Realtime channel that only that user can join.
- Mac updates are accepted only when signed with the project's Sparkle EdDSA key, and they arrive notarized.

Most valuable to hear about: anything that lets one account read or write another's data, reach the terminal bridge, or run the AI on someone else's server.
