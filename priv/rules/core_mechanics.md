# Fantasy RPG Game Mechanics Summary

Why: you learn by failing, as in life. Getting very good is slow on
purpose. See `PRODUCT.md` → Rules philosophy.

## Overview

This is a skill-based fantasy RPG system where character progress is measured by skills acquired and improved primarily through learning from failures, rather than traditional levels or experience points. The system uses a computer as the DM for bookkeeping, eliminating manual tracking burdens. Skills are rolled on a 1d20, with success determined by rolling equal to or below the skill level. There is no skill cap, allowing indefinite growth, though high levels require trainers or adventures to achieve.

## Core Skill Mechanics

- **Skill Rolls**:
  - Roll 1d20: Success if ≤ current skill level.
  - Natural 1: Exceptional success (narrative benefit, +1 LP, limited to once per skill per session).
  - Natural 20: Always a failure (+2 LP). For skills ≥15, treated as a "complicated success" (action succeeds with a drawback, still +2 LP).
- **Learning Points (LP)**:
  - Failure (non-natural 20): +1 LP.
  - Success (non-natural 1): +0.5 LP.
  - Natural 20: +2 LP.
  - Natural 1: +1 LP (capped once per skill per session).
  - Threshold: the tier's LP (Novice 1-5: 5, Adept 6-10: 7, Expert 11-15: 10, Master 16+: 15) and ≥ 1 failure on that skill to attempt improvement.
  - Linked stat: +(Stat - 10)/4 LP per roll (rounded down, 0 to +2).
- **Skill Improvement**:
  - Attempt at rest / sleep / wait ≥ 1 hour, not session end.
  - One 1d20 per eligible skill per pause.
  - Roll 1d20 &gt; raw skill (Expert -3 and Master -5 to the roll; Master needs a trainer).
  - Success: skill +1, LP 0, failures 0.
  - Failure: skill unchanged, LP 1, failures 0.
  - No skill cap; high levels become harder without bonuses.
- **Death Exception**: No LP from fatal failures; near-death grants +1 LP if survived.
- **Skill List Categories** (Examples):
  - **Combat**: Melee Combat, Ranged Combat, Unarmed Combat, Tactics, Dodge.
  - **Exploration**: Navigation, Survival, Tracking, Climbing, Stealth.
  - **Social**: Persuasion, Intimidation, Deception, Insight, Etiquette.
  - **Knowledge/Magic**: Arcana, History, Herbalism, Spellcasting, Ritual Magic.
  - **Craft/Utility**: Crafting, Lockpicking, Animal Handling, Alchemy, First Aid.

## Trainers and Adventures

- **Trainers**: NPCs with skill level ≥5 above the character's. Provide +5 bonus to improvement rolls (reduces target by 5).
  - Found via quests (e.g., journey to a master thief for Stealth training).
  - Bonus applies to one improvement per training session; requires time/resources.
  - Can be group quests for party training.
- **Integration**: Trainers can bypass/reduce stat minima for advancements; quests add narrative depth.

## Stats (STR, DEX, CON, INT, WIS, CHA)

- **Range**: 3-18 (rolled or point-buy).
- **Bonuses to Skill Rolls**: (Stat - 10)/2 (rounded down) added to effective skill level for related skills.
  - STR: Physical power (e.g., Melee, Climbing).
  - DEX: Agility/precision (e.g., Ranged, Stealth).
  - CON: Endurance (e.g., Survival, First Aid).
  - INT: Knowledge (e.g., Arcana, Herbalism).
  - WIS: Perception (e.g., Insight, Tracking).
  - CHA: Social (e.g., Persuasion, Deception).
- **Minimum Requirements for Advancement**:
  - Skills divided into tiers (Novice 1-5, Adept 6-10, Expert 11-15, Master 16+).
  - Min stat for higher tiers (e.g., STR ≥8 for Adept in Melee; increases per tier).
  - Auto-fail improvement if unmet; LP retained. Trainers can reduce minima.
- **Base Chance for Unskilled Attempts (Level 0)**:
  - Effective level = Stat / 3 (rounded down) for related tasks.
  - Adjustable by difficulty (/2 easy, /4 hard).
  - Failures/successes grant LP to start building the skill.
- **Additional Integrations**:
  - Derived Attributes: HP = 10 + (CON / 2) + other modifiers; damage bonuses from STR, etc.
  - LP Modifiers: (Stat - 10)/4 added to LP from failures/successes for linked skills (max +2).
  - Role-Playing Hooks: Stats gate equipment/actions (e.g., STR 13+ for greatswords); low stats prompt quests.

## Character Creation and Starting Allocation

- **Stats**: 75-point buy (min 3/max 18 per stat).
- **Skill Points**: 20-30 total to distribute (adjust for campaign).
  - Cost: 1 point per level 1-3; 2 points per level 4-5 (cap at 5 starting).
  - Stat Bonuses: +1 point per (stat &gt;10) for linked skills.
  - Backgrounds: Grant 3-5 free points in thematic skills (e.g., Warrior: +3 Melee, +2 Tactics).
  - Minimum: Allocate to at least 3-5 skills for diversity.
  - Wildcards: 1-2 extra points for quirks.
- **Computer DM Role**: Suggests builds, simulates practice rolls for feedback.