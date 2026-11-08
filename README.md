# GuildProf

A World of Warcraft addon for WoW Forever: which guild members can craft what.

Every member runs the addon. It reads the member's professions and known
recipes, shares them with the guild over addon messages, and shows the
whole guild's crafting in one window, offline members included. Nothing
leaves the guild.

## Status

In use on WoW Forever (1.60.x), the only target client. Releases:
[github.com/simonfou/GuildProf/releases](https://github.com/simonfou/GuildProf/releases).

## Install

1. Download **[GuildProf.zip](https://github.com/simonfou/GuildProf/releases/latest/download/GuildProf.zip)**
   (the latest release). GitHub's green **Code** button downloads the
   source tree instead, with files the game does not need.
2. In the Battle.net app, select World of Warcraft and its **Forever**
   version, click the gear next to **Play**, then **Show in Explorer**
   (**Show in Finder** on a Mac). Open `_forever_` if the window is not
   already in it, then `Interface`, then `AddOns`. Create `Interface` and
   `AddOns` if they are missing (exact spelling).
3. Double-click `GuildProf.zip` to open it and drag the **GuildProf**
   folder it contains into `AddOns`. The result is
   `AddOns\GuildProf\GuildProf.toc`. Windows' **Extract All** adds a
   second folder level (`AddOns\GuildProf\GuildProf\`), which the game
   does not load.
4. Quit and restart the game (a `/reload` does not pick up a new addon).
   At character select, **AddOns** lists GuildProf.

**Update**: delete the old `AddOns\GuildProf` folder, then repeat steps 1,
3 and 4. Shared data is kept in the game's `WTF` folder and survives
updates. When a guild member runs a newer version, GuildProf says so in
chat and at the top of its window; `/gp update` shows the download link,
ready to copy.

**Requirements**: every guild member who wants to share runs the addon.
Forever trial accounts cannot send addon messages, so they cannot share
their data.

## Use

- `/gp`, or the GuildProf tab on the side of the guild frame, opens the
  window: professions on the left; in the middle, the guild members who
  have the selected profession (skill, recipe count) followed by the
  recipes someone in the guild knows (with a search box); on the right,
  the selected recipe with its reagents and who can craft it.
- Hover a recipe or reagent for its item tooltip; shift-click a recipe to
  link it in chat; click a member to see only their recipes; right-click a
  member or click a crafter to whisper them.
- Recipes and skill levels are read from the spellbook at login and
  whenever they change: there is no need to open the profession windows.
  Opening one also rescans it.
- **Sync now** (in the window) or `/gp sync` rescans and asks the guild
  for updates right away.
- `/gp status` shows the guild, the number of records, the last scan, the
  message counters, the roster read and the last removal of departed
  members, and the addon versions seen in the guild. `/gp update` shows
  the download link. `/gp scan` rescans, `/gp debug` toggles debug
  output.

## Known limits

- A character who leaves the guild disappears from each member's list at
  that member's next guild roster update. Nothing is removed while the
  roster looks incomplete, or when most records would go at once.
- Two members who both missed a change while offline get it at the next
  login or **Sync now** of either one.

## How sharing works

Each character owns one record (levels and recipe IDs, about 2 bytes per
recipe) with a revision number; the newest revision wins. A login sends
a single digest of everything the player knows; when it matches, nothing
else is sent. When it differs, one guild member answers and the two
compare per-bucket digests by whisper, then exchange only the records that
differ. Details and measured message counts: [docs/design.md](docs/design.md).

Everything stays within the guild: messages go on the guild channel, and
whispers count only from players heard there. Another guild using the
addon keeps its own, separate list.

## Development

A release is the committed addon at the TOC's `## Version`: bump it,
commit, push, then `python3 -I tools/release.py --publish` builds
`dist/GuildProf.zip` (the addon folder only), tags `v<version>` and
creates the GitHub release. Without `--publish` it only builds the zip.

- Tests (Lua 5.1): `lua-5.1 tests/run.lua` loads the pure modules
  (`GuildProf/Core/`) and simulates a guild of 22 players on a virtual
  clock: convergence, message counts, name learning (`SEED=<n>` varies the
  timings). `lua-5.1 tests/ui_smoke.lua` runs the whole addon, window and
  guild frame tab included, against a fake client.
- Recipe data: `GuildProf/Data/Recipes.lua` is generated from the client's
  DB2 tables (SkillLine, SkillLineAbility, SpellEffect, SpellReagents) as
  CSV from wago.tools:
  `python3 -I tools/gen_recipes.py <csv_dir> <build> > GuildProf/Data/Recipes.lua`.
  Regenerate after a client patch.

## License

MIT, see [LICENSE](LICENSE).
