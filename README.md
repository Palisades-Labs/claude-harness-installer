# claude-harness-installer

The public first step of Claude setup for Palisades Labs customers. A team member
pastes one command from their company's setup guide; this script gets the Mac ready
and then hands over to the company's own private setup.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Palisades-Labs/claude-harness-installer/main/install.sh) <1password-sign-in-address> [--admin]
```

The argument is the company's 1Password sign-in address, for example
`yourteam.1password.com`. The setup guide gives each team member the exact command.

## What it does

1. Checks that this is a Mac and that the account is an administrator.
2. Installs Homebrew if it's missing. This is the one time it asks for the Mac password.
   It uses Homebrew's own installer, pinned to a reviewed version.
3. Installs the 1Password app and the 1Password command-line tool if they're missing.
4. Waits until 1Password is signed in to the company's account with the command-line
   integration turned on, and tells the person exactly what to do if it isn't.
5. Reads the item **Claude Setup Access** from the company's 1Password: its `repo`
   field (the private setup repo, `owner/name`) and its `credential` field (a read-only
   access key for that one repo). It saves the key in the Mac's Keychain for that repo
   only. The key is never shown, never passed as a command argument and never written
   to a file. Nobody needs a GitHub account.
6. Downloads the private repo to a temporary folder with that key, which also proves
   the access works, and runs its `setup/setup.sh`. That script does the rest and
   prints the final report.

## What it holds

No secrets and no customer data. The script is the same for every customer: everything
specific comes from the customer's own 1Password account. Running it with `--dry-run`
prints the plan without reading anything from 1Password or changing anything.

## Onboarding a new customer

1. In the customer's 1Password, in a vault their team members can read, create an item
   titled exactly **Claude Setup Access** with two fields:
   - `repo`: the private setup repo, as `owner/name`;
   - `credential`: a GitHub fine-grained personal access token for that one repo with
     read-only Contents and Metadata permissions, created by the repo's owner.
2. Make sure the private repo has `setup/setup.sh`. It is started with `HARNESS_SRC`
   (the downloaded copy) and receives `--admin` and `--dry-run` when given.
3. Write the customer's setup guide with the command above and their sign-in address.

## Files

- `install.sh`: the installer.
- `tests/test_install_dryrun.sh`: tests with every external tool stubbed. Run
  `shellcheck install.sh && bash tests/test_install_dryrun.sh`.
- `v2.sh`: the previous command, which needed each person to sign in to GitHub. It stays
  until the setup guides show the new command, then a separate change deletes it.

Questions: aaron@palisadeslabs.ai.
