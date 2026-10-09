# Fantasy RPG Game Mechanics Summary

Why: you learn by failing, as in life. Getting very good is slow on
purpose. See `PRODUCT.md` → Rules philosophy.

## Overview

This is a skill-based fantasy RPG system where character progress is measured by skills acquired and improved primarily through learning from failures, rather than traditional levels or experience points. The system uses a computer as the DM for bookkeeping, eliminating manual tracking burdens. Skills are rolled on a 1d20, with success determined by rolling equal to or below the skill level. There is no skill cap, allowing indefinite growth, though high levels require trainers or adventures to achieve.

## Core Skill Mechanics

- **Skill Rolls**:
  - Roll 1d20: Success if ≤ current skill level.
  - Natural 1: Exceptional success (narrative benefit). Earns no LP: nothing to learn from a success.
  - Natural 20: Always a failure (+1 LP). For skills ≥15, treated as a "complicated success" (action succeeds with a drawback, still +1 LP).
- **Learning Points (LP)** — you learn only from failure, only in the skill you failed:
  - Failure or partial success: +1 LP for that skill, a banked improvement chance. Nothing spills to other skills.
  - Success (natural 1 included): no LP.
  - The linked stat adds no LP: talent helps you succeed, not learn faster.
- **Skill Improvement** — it sinks in while you sleep:
  - Banked LP are spent on a long rest (sleep, or six hours or more of rest), one attempt per LP. Ordinary turns spend nothing.
  - Roll 1d20 ≥ 11 and ≥ raw skill: skill +1. Chance (21 - max(skill, 11))/20: 50% up to 11, 45% at 12, 25% at 16, 5% at 20. No attempt is a sure thing, not even at level 0.
  - Each attempt costs 1 LP, hit or miss. No tier modifiers.
  - No skill cap, but past 20 only a trainer's bonus can reach the target.
- **Death Exception**: No LP from fatal failures, and the dead learn nothing.
- **Skill List Categories** (Examples):
  - **Combat**: Melee Combat, Ranged Combat, Unarmed Combat, Tactics, Dodge.
  - **Exploration**: Navigation, Survival, Tracking, Climbing, Stealth.
  - **Social**: Persuasion, Intimidation, Deception, Insight, Etiquette.
  - **Knowledge/Magic**: Arcana, History, Herbalism, Spellcasting, Ritual Magic.
  - **Craft/Utility**: Crafting, Lockpicking, Animal Handling, Alchemy, First Aid.

## Trainers and Adventures

- **Trainers**: NPCs with skill level ≥5 above the character's. A training session is one free improvement attempt (no LP) with +5 to the roll (1d20 + 5 ≥ 11 and ≥ skill).
  - Found via quests (e.g., journey to a master thief for Stealth training).
  - One attempt per training session; costs time and the trainer's fee.
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
  - Failures grant LP to start building the skill.
- **Additional Integrations**:
  - Derived Attributes: HP = 10 + (CON / 2) + other modifiers; damage bonuses from STR, etc.
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