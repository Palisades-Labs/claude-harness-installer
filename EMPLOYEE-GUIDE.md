# Employee Install Guide — Claude Code Harness

This guide walks you through installing your team's Claude Code harness on your own computer. It should take about 10 minutes. By the end, you'll have Claude Code with your team's API tools (Tavily, Avoma, or whatever your team uses) ready to go.

You don't need to be a developer to follow this. You just need to be comfortable opening a terminal and pasting one command.

---

## Before you start — what you need

Make sure you have all of these before you begin. If anything is missing, install or request it first.

- **A computer running macOS, Linux, or Windows.**
- **Claude Code installed.** If you don't have it yet, install it from https://docs.claude.com/en/docs/claude-code/setup. Your admin can confirm which version to use.
- **Claude Desktop installed.** Download from https://claude.com/download. Sign in with the account your company uses.
- **The install message from your admin.** Should be in Slack, email, or wherever your team communicates. Keep it open in a browser tab — you'll paste from it in Step 2.
- **The passphrase from your admin.** Sent SEPARATELY from the install message, probably in 1Password, Bitwarden, a direct message, or given to you in person. You'll need this in Step 3. Keep it handy.

If you're missing the install message or the passphrase, reply to your admin before continuing.

---

## Step 1 — Add the marketplace in Claude Desktop

The "marketplace" is where Claude Desktop downloads your team's plugins from. You add it once, then it auto-syncs in the background.

1. **Open Claude Desktop.** This is the desktop app you installed. Not the website, not Claude Code (the terminal one). The desktop app has a chat window and a sidebar.

2. **Click your account name** (or avatar) in the top-right corner of the window. A menu appears.

3. **Click "Customize"** (or "Settings" depending on your version).

4. **Click "Personal plugins"** in the sidebar.

5. **Click "Add marketplace"** (sometimes labeled with a `+` icon).

6. **Type your team's harness repo name.** Your admin's message will tell you what to type — it looks like `Palisades-Labs/your-company-harness` or similar. Type that exactly. Click "Add."

7. **Wait for the green "Synced" status** to appear next to the marketplace name. This usually takes 10–30 seconds. The first time, Claude Desktop may ask you to sign in to GitHub — complete that flow with your GitHub account.

   If you see "Sync failed" or "Permission denied," reply to your admin — your GitHub account may need to be granted read access to the repo first.

8. **Confirm it's synced.** You should see your team's plugins listed under the marketplace name. Don't enable them yet (the next step handles that).

---

## Step 2 — Run the install command

The command decrypts your team's shared API keys onto your computer.

### If you're on Mac or Linux

1. **Open Terminal.** On Mac: press Cmd+Space to open Spotlight, type "Terminal", press Enter. On Linux: open your distro's terminal app (Gnome Terminal, Konsole, etc.).

2. **Copy the Mac / Linux command block from your admin's message.** There's probably a copy button on the code block — click it. Otherwise select the whole line with your mouse and press Cmd+C (Mac) or Ctrl+C (Linux).

3. **Paste into Terminal.** Click inside the Terminal window to focus it, then press Cmd+V (Mac) or Ctrl+Shift+V (Linux).

4. **Press Enter.**

You should see output that starts with `[bootstrap] Client repo:` and continues from there.

### If you're on Windows

1. **Open PowerShell.** Press the Windows key to open the Start menu, type "PowerShell", and click "Windows PowerShell" in the results.

2. **Copy the Windows command block from your admin's message** — ALL FOUR LINES together. Do not copy them one at a time; select all four lines and copy them as one block.

3. **Paste into PowerShell.** Click inside the PowerShell window to focus it, then press Ctrl+V or right-click and select Paste.

4. **Press Enter.**

---

## Step 3 — Enter the passphrase when prompted

Partway through the install, the script will print:

```
[bootstrap] Setup passphrase:
```

…and then it'll pause.

1. **Get the passphrase your admin sent you separately.** Open 1Password (or Bitwarden, or the Slack DM, or wherever you got it). Copy the passphrase value.

2. **Paste it into the terminal.**

3. **IMPORTANT: nothing will appear on screen as you paste.** The cursor won't move. No characters show up. That's on purpose — the passphrase is hidden for security. The terminal is just silently receiving what you pasted.

4. **Press Enter.**

If you entered the right passphrase:
- You'll see `[bootstrap] [ok] Credentials decrypted to ~/.claude/credentials/credentials.env`.
- Followed by `[bootstrap] Bootstrap complete.`

If the passphrase was wrong:
- You'll see an error like "Wrong passphrase — could not be decrypted."
- Re-run the command (pressing Up arrow recalls it) and try again. Triple-check the passphrase — sometimes an extra space gets copied.

---

## Step 4 — Open a new terminal and start Claude Code

This is the part people forget, so do it exactly.

1. **CLOSE the terminal window you just used.** Not just minimize — close it entirely (Cmd+Q on Mac; X button on Windows/Linux).

2. **Open a FRESH terminal window** the same way you did in Step 2. This is important — the install added some settings, and only a brand-new terminal will pick them up.

3. **Type `claude`** and press Enter.

4. **Claude Code should start.** You're done.

If you see `command not found: claude`, Claude Code isn't installed yet — go back to the prerequisites section and install it, then come back to Step 4.

---

## Verifying it worked

In Claude Code, try one of your team's skills. Your admin will tell you which one to try (for example, if your team uses Avoma, they might say "try `/summarize-avoma-call`"). If the skill runs and returns real data (not an error about a missing API key), the install worked.

If you get errors about missing API keys, reply to your admin — something may have gone wrong at Step 2 or Step 3.

---

## Common problems

### "command not found: claude"
Claude Code isn't installed on your machine, or it's installed somewhere your terminal can't find. Install from https://docs.claude.com/en/docs/claude-code/setup and try again.

### "credentials.env.age not found — marketplace not synced yet"
Go back to Step 1 and wait for the green "Synced" status before re-running the install command. If it's been more than 2 minutes and still no sync, remove and re-add the marketplace.

### "Wrong passphrase — could not be decrypted"
The passphrase you entered doesn't match. Double-check by copying it fresh from your password manager. If you're pasting from Slack, make sure you don't have an extra space at the beginning or end. If you're certain the passphrase is right, ask your admin to verify it.

### The terminal seems frozen at the passphrase prompt
It's not frozen — it's waiting for you to paste the passphrase. Nothing appears on screen as you type or paste. Paste the passphrase and press Enter.

### "Permission denied" or weird shell errors
Try opening a brand-new terminal window and running the command again. If that doesn't help, reply to your admin with a screenshot of the error.

### "age is not installed"
The installer should install `age` for you automatically. If you see this error, the script version you're running is old. Ask your admin to send you a fresh copy of the install command.

### I accidentally pasted the passphrase into the Claude Code chat instead of the terminal
Don't panic. Tell your admin — they'll rotate the passphrase. Delete the chat message if you can.

### The install finished but when I open Claude, nothing works
Make sure you opened a NEW terminal window after the install finished (Step 4). The install writes some settings to a config file that only loads in fresh terminals.

### I'm on Windows and the command split into pieces when I pasted
Make sure you copied all four lines together before pasting. Chat apps sometimes wrap long lines, and the paste can break into pieces. Select all four lines at once, copy, then paste into PowerShell in one shot.

---

## What just happened (optional reading)

In plain English:

1. Your team has shared API keys (Tavily, Avoma, etc.) that skills use when you invoke them in Claude Code.
2. Your admin encrypted those keys into a file (`credentials.env.age`) and pushed it to your team's private GitHub repo.
3. Claude Desktop cloned that repo onto your machine when you added the marketplace.
4. The install command ran a script that took the encrypted file, prompted you for the passphrase, decrypted it, and saved the plaintext keys to a protected file on your machine (`~/.claude/credentials/credentials.env` on Mac/Linux; equivalent on Windows).
5. The script also added a line to your terminal's startup config so the keys auto-load as environment variables every time you open a new terminal.
6. When a skill needs (for example) `TAVILY_API_KEY`, it reads it from the environment and makes the API call. The key never appears in your Claude chat context.

That's the whole system. Your admin manages the credentials centrally; your machine decrypts them locally; Claude Code uses them automatically.

---

Any questions, reply to your admin or ask in your team's Claude Code channel.
