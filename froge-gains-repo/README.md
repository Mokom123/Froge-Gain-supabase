# Froge Gains: backend and web pages

```
web/                    pages users see in the browser (GitHub Pages)
  index.html            landing page
  confirmed.html        shown after a user clicks the confirmation link in their email
  verify.html           "check your inbox" page with a Resend button
  reset.html            forgot / reset password page
  privacy.html          Privacy Policy
  terms.html            Terms of Use
  config.js             your Supabase URL, anon key and contact email (edit once)
supabase/
  *.sql                 database phases, in order (run new ones in the SQL Editor)
  functions/            Edge Functions (deployed automatically)
  config.toml           which functions run without a login token
.github/workflows/      the two auto-deploy jobs
```

## One-time setup (about 20 minutes)

### 1. Put it on GitHub
1. Create a new repository on github.com (for example `froge-gains`). Private is fine for the backend, but GitHub Pages on a free account needs a **public** repo. Easiest: make it public. It contains no secrets: config.js holds only the public anon key.
2. Upload everything in this folder (drag the files into the repo page, or use `git push`). Include the hidden `.github` folder.

### 2. Fill config.js
Open `web/config.js` and set:
- `SUPABASE_URL` and `SUPABASE_ANON_KEY` (Supabase > Project Settings > API; use the **anon public** key, never `service_role`)
- `CONTACT_EMAIL` (shown in the Privacy Policy and Terms)

### 3. Turn on the website
Repo > Settings > Pages > Source: **GitHub Actions**. Push anything under `web/` (or Actions tab > "Deploy web pages" > Run workflow). After a minute your site is at
`https://YOUR-USERNAME.github.io/REPO-NAME/` (this is your **site address** below).

### 4. Tell Supabase about the pages
Supabase > Authentication > URL Configuration:
- **Site URL:** `SITE_ADDRESS/confirmed.html`
- **Redirect URLs** (add all):
  - `SITE_ADDRESS/confirmed.html`
  - `SITE_ADDRESS/reset.html`
  - `SITE_ADDRESS/verify.html`
  - `froge://login-callback/`

Supabase > Authentication > Email: keep "Confirm email" ON.

### 5. Tell the app
In `lib/auth.dart` set
```dart
const confirmPageUrl = 'SITE_ADDRESS/confirmed.html';
```
Then rebuild the APK. New users now get an email whose link lands on the confirmed page, with an "Open the app" button.
For the Privacy Policy and Terms links (Google sign-in screen, Play Store) use `SITE_ADDRESS/privacy.html` and `SITE_ADDRESS/terms.html`.

Forgot password: users can open `SITE_ADDRESS/reset.html`, type their email, get a link, and set a new password. (A "Forgot password?" button in the app that opens this page can be added in the next update.)

### 6. Auto-deploy the functions
Repo > Settings > Secrets and variables > Actions > New repository secret:
- `SUPABASE_ACCESS_TOKEN`: supabase.com/dashboard/account/tokens > Generate new token
- `SUPABASE_PROJECT_REF`: the short id in your project URL (`https://<ref>.supabase.co`)

Function secrets (PUSH_SECRET, FCM_SERVICE_ACCOUNT, TELEGRAM_BOT_TOKEN, X_CLIENT_ID, GOOGLE_CLIENT_ID and so on) stay in Supabase > Edge Functions > Secrets. They are set once there and are never stored in GitHub.

From now on, pushing a change under `supabase/functions/` redeploys the functions by itself.

## Database changes
SQL files are applied by hand: Supabase > SQL Editor > New query > paste the file > Run. Run them in numeric order (`schema.sql`, `phase1`, `phase2`, ... `phase23`, with the `b` / `c` files and the `_schedule.sql` files right after their number). The schedule files need your project ref and PUSH_SECRET placeholders filled in before running. Every file is safe to run twice.

## Before you launch
The Privacy Policy and Terms are a solid starting template written for this app, not legal advice. Have a lawyer in Cameroon (or wherever you operate) read them, especially the game-bet section, before real launch.
