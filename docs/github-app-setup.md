# GitHub App setup

ai-review can post reviews under a dedicated bot identity (e.g.
`my-review-bot[bot]`) instead of your personal `gh` login. This keeps
review threads visually distinct from your own comments and avoids
notification noise on your account.

## Create the App

1. Open <https://github.com/settings/apps/new>.
2. **App name:** anything globally unique (e.g. `myrepo-review-bot`).
3. **Homepage URL:** the repo URL (`https://github.com/<owner>/<repo>`).
4. **Webhook:** uncheck "Active" — ai-review doesn't use webhooks.
5. **Permissions:**

   | Permission     | Access       |
   |----------------|--------------|
   | Pull requests  | Read & write |
   | Contents       | Read-only    |
   | Metadata       | Read-only    |

6. **Where can this GitHub App be installed?** → "Only on this account".
7. **Create GitHub App.**

## Install + collect credentials

1. On the App's settings page, scroll to **Private keys** → **Generate
   a private key**. A `.pem` file downloads. Move it somewhere safe.
2. Note the **App ID** at the top of the settings page.
3. In the left sidebar, click **Install App** → choose the account →
   pick **Only select repositories** → select your repo → install.
4. After install, the URL ends with `/settings/installations/<INSTALL_ID>` —
   note that number.

## Wire it into ai-review

`ai-review --init` walks you through this and writes the conf file for
you. If you'd rather do it manually:

```bash
mkdir -p ~/.config/ai-review/apps
cat > ~/.config/ai-review/apps/<owner>__<repo>.conf <<EOF
APP_ID=<the App ID>
INSTALL_ID=<the Installation ID>
PRIVATE_KEY=$HOME/.config/ai-review/apps/<owner>__<repo>.pem
EOF
mv ~/Downloads/<your-key>.pem ~/.config/ai-review/apps/<owner>__<repo>.pem
chmod 600 ~/.config/ai-review/apps/<owner>__<repo>.pem
```

The lookup key is `<owner>__<repo>` (double underscore). ai-review picks
this up automatically when you run inside a clone of that repo.

## Per-repo or shared

Each `.conf` in `~/.config/ai-review/apps/` corresponds to one repo.
A single GitHub App can be installed on multiple repos — duplicate the
`.conf` (one per `<owner>__<repo>.conf`) and point each at the same
`.pem` to share the App across them.

## Falling back

If no `.conf` exists for the current repo and `AI_REVIEW_IDENTITY=auto`
(the default), ai-review posts under your `gh` login. To force this
explicitly:

```bash
AI_REVIEW_IDENTITY=gh-user ai-review
```

To force App auth and fail loudly when the conf is missing:

```bash
AI_REVIEW_IDENTITY=app ai-review
```
