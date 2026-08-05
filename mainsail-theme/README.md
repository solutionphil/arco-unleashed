# ARCO UNLEASHED — Bookworm Edition · Mainsail Theme

Electric-cobalt comic theme matching the Arco Unleashed branding: navy glass
panels, halftone-burst background, brand-blue accents, the bookworm logo.

## Files
| File | Purpose |
|------|---------|
| `custom.css` | UI styling — accents, panels, sidebar, scrollbar, table/console |
| `main-background.svg` | Comic halftone-burst page background (subtle, stays readable) |
| `sidebar-logo.png` | Bookworm logo at the top of the sidebar |
| `favicon-16x16.png` / `favicon-32x32.png` | Bookworm browser-tab icon (the names Mainsail reads) |
| `favicon-source.svg` | Editable vector source for the favicon |
| `apple-touch-icon.png`, `android-chrome-*.png` | Optional extras for mobile home-screen / PWA |

## Two variants: Voron Light & Voron Dark
Mainsail can't add *named* custom themes to its dropdown (that needs a Mainsail
fork/rebuild, which breaks on every update). Instead this kit ships **two variants**
and a switcher script:

- **Voron Light** — navy base (`#070E1F`), the default.
- **Voron Dark** — near-black base (`#02050c`), same accents / logo / favicon.

Layout in `printer_data/config/`:
```
.theme/                     ← the ACTIVE variant (Mainsail reads this; rebuilt by the script)
.theme-variants/
  shared/      sidebar-logo.*, favicon-*        (identical for both)
  voron-light/  custom.css, main-background.svg
  voron-dark/custom.css, main-background.svg
unleashed-theme.sh              ← switcher
```

### Install
```bash
# copy the variant tree + script into the config dir, then:
chmod +x ~/printer_data/config/unleashed-theme.sh
sh ~/printer_data/config/unleashed-theme.sh light      # activate the default
```
Hard-reload Mainsail (Ctrl+F5). `.theme*` are hidden — enable *Show Hidden Files*
in the file-manager cog menu to see them.

### Switching
```bash
sh ~/printer_data/config/unleashed-theme.sh next      # cycle light → dark → stock → light …
sh ~/printer_data/config/unleashed-theme.sh light      # set explicitly
sh ~/printer_data/config/unleashed-theme.sh dark
sh ~/printer_data/config/unleashed-theme.sh stock     # stock Mainsail (theme off)
sh ~/printer_data/config/unleashed-theme.sh           # show active state
sh ~/printer_data/config/mainsail-stock.sh        # dedicated stock reset
```
Each switch rebuilds `.theme/` from `shared/` + the chosen variant; then Ctrl+F5.
The last state is stored in `.theme-state` (a file *outside* `.theme/`, so it survives
both `stock` — which removes `.theme/` — and reboots). Nothing re-applies a theme on
boot, so the printer comes up in whatever state it was last left in.

**One-click in Mainsail** (included): a single macro `SWITCH_THEME` appears in the
Macros panel and cycles Bright → Dark → Stock on each click — then Ctrl+F5. Setup
(one time):
1. copy `../scripts/gcode_shell_command.py` → `~/klipper/klippy/extras/` *(it moved out of this folder: the
   base `AddOn.cfg` needs it too, so it lives with the other Klipper extras and is reinstalled
   automatically by `apply-arco-extras.sh` on every Klipper start)*
   (the standard Arksine extension, e.g. from Frix-x/klippain)
2. copy `unleashed-theme-macros.cfg` → `~/printer_data/config/`
3. add `[include unleashed-theme-macros.cfg]` to `printer.cfg`
4. `RESTART` Klipper

`setup-theme-macros.sh` does steps 2–4 automatically. The switcher builds `.theme/`
in a temp dir and swaps it atomically, so rapid clicks never corrupt the theme.

> Note: the `.theme` overlay is global, so it also tints the other built-in themes.
> Keeping the built-in themes fully pristine would require a Mainsail fork (not
> update-safe) — out of scope for this kit. The one dropdown-selectable piece that
> still works natively is the Primary Color: `#2E74F2`.

## Favicon / logo alternatives
`favicon-source.svg` is the active **Burst „U"** mark. Also in the repo:
`favicon-alt-wormhead.svg` (bookworm head) and `favicon-alt-burst.svg` (Burst „A").
Regenerate any letter mark with `gen_fav_burst.py` (change the letter, one line).

## Best result
For the cleanest accent, set the primary color to the brand blue:
**Mainsail → Settings → General → Primary Color → `#2E74F2`**
(`custom.css` already pushes most elements there, but this nails the rest.)

## Brand palette
| Token | Hex |
|-------|-----|
| ARCO electric blue | `#2E74F2` |
| Highlight / hover | `#5B97FF` |
| Panel navy | `#0E2247` |
| App background ink | `#070E1F` |

## Optional
- Swap `sidebar-logo.png` for a square crop (just the bookworm) if you prefer a compact mark.
- Add `favicon-32x32.png` / `favicon-16x16.png` (square) to brand the browser tab.
