# GuildProf

A World of Warcraft addon for WoW Forever: which guild members can craft what.

Every member runs the addon. It reads the member's professions and known
recipes, shares them with the guild over addon messages, and shows the
whole guild's crafting in one window, offline members included. Nothing
leaves the guild.

## Status

Early development, not released yet. Target client: WoW Forever (1.60.x).

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
- `/gp status` shows the guild, the number of records, the last scan and
  the message counters. `/gp scan` rescans, `/gp debug` toggles debug
  output.

## How sharing works

Each character owns one record (levels and recipe IDs, about 2 bytes per
recipe) with a revision number; the newest revision wins. A login sends
a single digest of everything the player knows; when it matches, nothing
else is sent. When it differs, one guild member answers and the two
compare per-bucket digests by whisper, then exchange only the records that
differ. Details and measured message counts: [docs/design.md](docs/design.md).

## Development

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
