# tcg-set-credits

A small PowerShell utility that sets the **credit balance** for the
[OSRS-TCG](https://github.com/Azderi/osrs-tcg) RuneLite plugin by editing its
save data on your own machine.

> Personal utility. Not affiliated with or endorsed by the OSRS-TCG plugin or its author.

## What it does

The plugin stores its state (credits, opened packs, collection) in RuneLite's
profile config and in file backups under `~/.runelite`, encoded as
`RLTCG_v2:<base64(xor(gzip(json)))>` and protected by a SHA-256 integrity hash.

This script decodes that blob, changes **only** the `credits` value, re-encodes it,
recomputes the hash, and writes it back to every place the plugin loads from. It
edits each RuneScape account profile **independently** (your other accounts'
collections are never touched) and copies your originals to a timestamped folder
before making any change.

## Usage

**Close RuneLite completely first** — otherwise it overwrites the edit on logout.

```powershell
# interactive – lists your accounts and asks for the amount
powershell -NoProfile -ExecutionPolicy Bypass -File .\tcg-set-credits.ps1

# non-interactive
powershell -NoProfile -ExecutionPolicy Bypass -File .\tcg-set-credits.ps1 -Credits 5692500 -Yes

# only one account (substring of the profile id, e.g. A1b2C3d4)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tcg-set-credits.ps1 -Credits 5000000 -Account A1b2C3d4 -Yes
```

A Standard pack costs 2,500 credits, so `credits = packs × 2500`
(e.g. a maxed 2,277 total level as "one pack per level" = `5692500`).

## Run without cloning

Because the repo is private, fetch it with the authenticated GitHub CLI
([`gh auth login`](https://cli.github.com/) once) and run it straight from memory —
nothing is saved to disk:

```powershell
# interactive
& ([scriptblock]::Create((gh api repos/Goku67HoodWars/tcg-set-credits/contents/tcg-set-credits.ps1 -H "Accept: application/vnd.github.raw" | Out-String)))

# direct
& ([scriptblock]::Create((gh api repos/Goku67HoodWars/tcg-set-credits/contents/tcg-set-credits.ps1 -H "Accept: application/vnd.github.raw" | Out-String))) -Credits 5692500 -Yes
```

It always pulls the current `main`, so pushing an update makes the next run use it
automatically. (Plain `iex` won't work here because the script has a `param()` block —
`[scriptblock]::Create` handles that.)

Optional one-word shortcut — add to your PowerShell profile (`notepad $PROFILE`):

```powershell
function Set-TcgCredits {
  & ([scriptblock]::Create((gh api repos/Goku67HoodWars/tcg-set-credits/contents/tcg-set-credits.ps1 -H "Accept: application/vnd.github.raw" | Out-String))) @args
}
```

Then run `Set-TcgCredits` (or `Set-TcgCredits -Credits 5692500 -Yes`).

## Notes / limits

- **Windows PowerShell only.**
- **Restore point:** originals are copied to
  `~/.runelite/OSRS-TCG/pre-edit-backup-<timestamp>/` before anything is changed.
- **Fragile by design:** if the plugin changes its save format (new version prefix
  or XOR salt), this stops working until updated.
- **Keep it to yourself / opt-in play.** This bypasses the plugin's anti-cheat.
  Leave **"Share collection online" off** so you're not pushing edited stats to the
  public album, and don't use it to affect trades with other players.
