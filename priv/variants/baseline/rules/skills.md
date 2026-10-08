# Skill Domains and Progression System

This document defines the skill domain architecture for the RPG system, establishing how skills group together, transfer between each other, and scale with mastery.

Why: as you get better you see general patterns, not just exact moves.
Related skills transfer. See `PRODUCT.md` → Rules philosophy.

---

## The Five Domains

Skills are organized into five **Domains** — broad categories sharing underlying physical, mental, or social foundations.

### Domain Definitions

| Domain | Core Attributes | Description |
|--------|----------------|-------------|
| **Martial** | STR, DEX, CON | Combat and physical confrontation |
| **Finesse** | DEX, INT | Precision, stealth, and manipulation |
| **Social** | CHA, WIS | Interpersonal influence and perception |
| **Knowledge** | INT, WIS | Academic learning and lore |
| **Craft** | INT, DEX | Creation, repair, and practical application |

---

## Skill → Domain Mappings

### Martial Domain
- Melee Combat
- Ranged Combat
- Unarmed Combat
- Dodge
- Tactics
- Throwing
- Shield Use

### Finesse Domain
- Stealth
- Lockpicking
- Sleight of Hand
- Climbing
- Acrobatics
- Pickpocket
- Escape Artist

### Social Domain
- Persuasion
- Deception
- Intimidation
- Insight
- Etiquette
- Performance
- Bargaining
- Leadership

### Knowledge Domain
- Arcana
- History
- Herbalism
- Nature
- Religion
- Medicine
- Geography
- Law

### Craft Domain
- Crafting (General)
- Alchemy
- First Aid
- Cooking
- Smithing
- Leatherworking
- Carpentry
- Enchanting

---

## Progression Tiers

| Tier | Level Range | Phase | Hours (~) | Real-World Equivalent |
|------|-------------|-------|-----------|----------------------|
| **Novice** | 1-5 | Cognitive | 0-100 | Hobbyist, casual practitioner |
| **Adept** | 6-10 | Associative | 100-1,000 | Serious amateur, professional basics |
| **Expert** | 11-15 | Autonomous | 1,000-3,000 | Working professional, instructor |
| **Master** | 16-20 | Deliberate Practice | 3,000-10,000 | World-class, decades of dedication |

### Hours Formula (Power Law)
```
Hours = 10,000 × (Level / 20)³
```

---

## Domain Affinity (Intra-Domain Transfer)

When you reach threshold levels in one skill, related skills in the **same domain** gain a **floor** — you can't be truly incompetent at related things.

| Highest Skill in Domain | Floor for Other Domain Skills |
|-------------------------|-------------------------------|
| 1-9 | 0 (skills are still islands) |
| 10-14 | 2 (patterns starting to connect) |
| 15-17 | 4 (flow state, unconscious competence) |
| 18-20 | 6 (universal principles visible) |

**Note**: The floor applies only to skills the character has NOT trained. If they have actual skill levels, use the higher of floor or trained level.

---

## Summit Sight (Cross-Domain Recognition)

At **Level 18+** in any skill, masters gain the ability to **recognize principles** in other domains.

### Mechanical Effects
- **Narrative Recognition**: GM describes cross-domain insights
- **First Attempt Bonus**: +2 to initial tries at new "spiritually adjacent" skills
- **Accelerated Learning**: +1 LP per roll when attempting recognized skills

### Spiritually Adjacent Skills
Skills are "spiritually adjacent" when they share underlying principles despite being in different domains:

| Master Skill | Adjacent Skills (Other Domains) |
|--------------|--------------------------------|
| Melee Combat | Performance (dance), Crafting (weapons) |
| Stealth | Tactics, Deception |
| Persuasion | Performance, Leadership |
| Arcana | Alchemy, Enchanting |
| Smithing | Melee Combat (weapon feel), Alchemy (metallurgy) |

---

## Attribute Echo (Skill → Stat Feedback)

High skill levels in a domain grant **contextual stat bonuses** when performing domain-related tasks.

| Domain Mastery Level | Stat Bonus (in-domain only) |
|---------------------|----------------------------|
| 10-14 (Adept) | +1 to linked attributes |
| 15-17 (Expert) | +2 to linked attributes |
| 18-20 (Master) | +3 to linked attributes |

**Example**: A Level 15 Melee Combat character (Martial domain) gets +2 to effective STR, DEX, and CON when performing any Martial domain action.

---

## LP Progression: Scaled Thresholds

| Tier | Level Range | LP to Attempt | Improvement Target | Trainer Required |
|------|-------------|---------------|-------------------|------------------|
| Novice | 1-5 | 5 LP | Roll > Level | No |
| Adept | 6-10 | 7 LP | Roll > Level | No |
| Expert | 11-15 | 10 LP | Roll - 3 > Level | Recommended |
| Master | 16-20 | 15 LP | Roll - 5 > Level | Required |

### Trainer Bonuses
- Trainers must have skill level ≥5 above student
- Trainer provides +5 bonus to improvement roll
- At Master tier, improvement without trainer auto-fails

---

## Design Rationale

### Why Domains?
Skills don't exist in isolation. A master swordsman has developed body awareness, timing, and spatial reasoning that transfers to other physical disciplines. Domains capture this reality.

### Why Floors Instead of Bonuses?
Floors represent baseline competence, not enhancement. A master fighter doesn't get +6 to unarmed — they can't be *worse* than level 6 at unarmed. This distinction matters narratively.

### Why Scaled LP?
The 10,000-hour research shows diminishing returns at high levels. A novice improves rapidly; a master grinds for marginal gains. Scaling LP thresholds simulates this reality.

### Why Trainer Requirements?
Beyond Expert level, self-study plateaus. Real masters seek other masters. This creates natural quest hooks and emphasizes that true mastery is rare.
