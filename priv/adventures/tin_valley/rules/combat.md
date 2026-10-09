# Combat System Summary for Skill-Based Fantasy RPG

## Overview
This combat system, adapted from Savage Worlds' wound-based mechanics, is designed for a skill-centered fantasy RPG where progression emphasizes learning from failures. It is fast-paced, dangerous, and exciting, using minimal rules to ensure quick resolution while integrating with the core system (1d20 skill rolls, success on ≤ skill level, no skill cap, LP-driven improvement, and six stats from 3-18). The computer DM handles bookkeeping, tracking wounds, initiative, and LP seamlessly.

## Core Mechanics
- **Wound Track**:
  - Characters/NPCs: 3 wounds base + (CON - 10)/2 (rounded down). E.g., CON 18 = 7 wounds; CON 10 = 3; CON 3 = 1 minimum.
  - Mooks (minor foes): 1 wound; major enemies: 3-5 wounds.
  - At 0 wounds: Incapacitated (unconscious, needs rescue). Excess hit triggers death roll (d20 > CON/2 or die).
- **Initiative**:
  - Roll Tactics or Dodge (d20, success on ≤ skill level) each round; highest successes act first, ties favor players then DEX stat.
  - Computer DM rerolls initiative per round for dynamic pacing.
- **Attacks**:
  - Roll combat skill (Melee, Ranged, Unarmed) vs. Parry (Dodge/2 + 10 + (DEX - 10)/2).
  - Success (≤ skill level, not 20): Roll damage (1d6 + STR/3 for melee/unarmed, +DEX/3 for ranged, rounded down) vs. Toughness (5 + armor + CON/2).
  - Natural 1: Exceptional hit (double damage or narrative bonus, e.g., disarm).
  - Natural 20: Fumble (+2 LP; computer DM narrates setback, e.g., slip).
  - Damage Outcomes:
    - < Toughness: No effect.
    - ≥ Toughness: Shaken (lose next action unless WIS/2 roll succeeds).
    - ≥ Toughness + 4: 1 wound + Shaken (or +1 wound if Shaken).
    - Mooks die on 1 wound; others take wounds up to max.
- **Learning Points (LP)**:
  - Miss (Natural 20 included): +1 LP for the skill rolled. A hit earns none.
  - Nothing spills to other skills.
  - Combat skills and dodge are physical: their LP are resolved at the end of the turn of the miss, not on a rest: ceil(skill / 3) LP per roll, d20 ≥ 11 and ≥ skill level: +1, at most +1 per skill between two long rests; from skill 10 only after reflecting on it. Other skills rolled in a fight (deception, intimidation) wait for sleep.

## Additional Features
- **Multi-Actions**: Multiple actions per round (e.g., attack twice) at -2 skill per extra action, granting LP on failures.
- **Tactical Options**:
  - Reckless: +2 attack skill, -2 Parry next round.
  - Defensive: +2 Parry, -2 attack skill.
  - Trick (Deception/Intimidation): Success lowers foe’s Parry by 2 (+1 LP on fail).
- **Group Advantage**: +1 attack roll per ally engaged with target.
- **Recovery**: Post-combat, First Aid (≤ skill level) heals 1 wound per success (once per ally per fight). Otherwise, 1 wound/day with CON/2 roll success.
- **Computer DM**: Tracks wounds, initiative, LP; adds environmental effects (e.g., -1 Dodge on mud) or fumble tables for flavor.

## Design Goals
- **Deadly**: Low wounds (1-7) and high damage (~4 average) resolve fights in 2-4 rounds.
- **Fast-Paced**: Simple rolls and initiative keep combat swift.
- **Exciting**: Tactical choices and dynamic initiative add cinematic tension.
- **Skill-Centric**: Skills drive outcomes, with stats as modifiers; failures fuel LP for growth.
- **Trainer Integration**: Trainers (+5 to improvement rolls) or stat-boosting quests ease high-skill advancement.