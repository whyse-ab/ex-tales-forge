# Labor-Anchored Economy System

Why: fewer non-intuitive rules make it easier to stay in the story. Prices
are a guess at **effort**, as in our world — not a loot table. See
`PRODUCT.md` → Rules philosophy.

The economy uses a **labor-based pricing model** where every price derives from the human effort required to produce an item or service.

---

## The Immutable Anchor

Throughout history, the value of 1 oz of gold has consistently equaled approximately **one month of skilled craftsman labor**:

| Era | Example Item | Gold Value | Labor Input |
|-----|--------------|------------|-------------|
| Roman Empire | Fine toga | ~1 oz gold | Months of weaving |
| Victorian Britain | Bespoke suit | ~1 oz gold | Months of tailoring |
| Modern Day | Tailored suit | ~1 oz gold | Months of skilled work |

**In Our System**: 
- **2g = 1 month of skilled labor** (THE ANCHOR)
- **1g = ~2 weeks of skilled work**
- **1s = ~3 hours of skilled work** (or half a day unskilled)
- **1c = ~20 minutes of unskilled work**

---

## Coin Denominations

| Denomination | Symbol | Relative Value | Weight | Labor Equivalent |
|--------------|--------|----------------|--------|------------------|
| Gold | g | 1 | 0.5 oz | ~2 weeks skilled work |
| Silver | s | 1/50 | 0.5 oz | ~3 hours skilled work |
| Copper | c | 1/500 | 0.3 oz | ~20 min unskilled work |

**Conversion**: 1 gold = 50 silver = 500 copper

---

## Price Derivation: Labor Categories

Prices derive from THREE labor factors:
1. **Duration**: How long does production take?
2. **Intensity**: Constant attention vs passive processes?
3. **Skill Level**: Unskilled, skilled, or master craftsman?

### Category 1: Minimal/Passive Labor (Coppers)

Items where human effort is minimal — nature does most of the work.

| Item | Price | Labor Reality |
|------|-------|---------------|
| Ale, mug | 2c | Combine water, grain, hops → ferments itself. Stirring/testing only. |
| Bread loaf | 1c | Mix, knead (15 min), wait for rise, bake. Bulk production. |
| Cheese wedge | 3c | Milk + rennet → curds form passively. Aging is waiting. |
| Eggs (dozen) | 2c | Chickens do the work. Just collection. |
| Salted fish | 4c | Catch (shared boat effort), salt, dry. Bulk processing. |
| Tallow candle | 1c | Rendered fat + wick. Simple dipping, minutes of work. |
| Common meal | 5c | Basic ingredients, quick preparation |

**AI Reasoning**: "Does this item mostly make itself? Is it bulk-processed? → Coppers"

### Category 2: Harvesting-Intensive (High Coppers to Low Silvers)

Items requiring significant manual collection or tending by crews.

| Item | Price | Labor Reality |
|------|-------|---------------|
| Wine, common | 15c | Grape picking (crews), crushing, fermenting (passive), bottling |
| Wine, fine | 2-5s | Careful selection, longer aging, more attention |
| Honey pot | 8c | Beekeeping (seasonal), extraction, filtering |
| Linen cloth (yard) | 5c | Flax growing (passive), but harvesting + processing is work |
| Wool cloth (yard) | 8c | Shearing (quick), but spinning + weaving takes time |
| Spices (pouch) | 10-50s | Harvesting + long-distance transport (rare, imported) |

**AI Reasoning**: "Multiple workers involved? Seasonal timing? Transport required? → Silvers"

### Category 3: Individual Crafting (Silvers to Gold)

Items where a single craftsman dedicates focused hours or days.

| Item | Price | Labor Reality |
|------|-------|---------------|
| Dagger | 10s | Blacksmith: 4-6 hours of forging, shaping, sharpening |
| Common sword | 1g | Blacksmith: 2-3 days of skilled work |
| Quality boots | 15s | Cobbler: Full day of cutting, stitching, fitting |
| Leather armor | 2g | Leatherworker: Week of cutting, hardening, riveting |
| Beeswax candles | 5c | More refined process than tallow, still quick |
| Iron pot | 8s | Casting or forging, half-day of smith work |
| Private room (night) | 3s | Innkeeper's service + opportunity cost |

**AI Reasoning**: "One craftsman, focused hours/days of skilled work? → Silvers to low Gold"

### Category 4: Master Craftsmanship (Gold)

Items representing weeks or months of dedicated skilled labor.

| Item | Price | Labor Reality |
|------|-------|---------------|
| Tailored noble outfit | 2g | THE ANCHOR — 1 month of master tailor's work |
| Fine sword | 3-5g | Master smith: 1-2 weeks of expert forging |
| Chainmail | 15g | Months of ring-making, linking (tedious, skilled) |
| Plate armor | 80-120g | Year+ of master armorer's dedicated work |
| Jewelry, fine | 5-20g | Goldsmith: Weeks of delicate work + materials |
| Illuminated book | 10-30g | Scribe: Months of copying, illustrating |
| Horse (riding) | 15g | Years of breeding, training, feeding |

**AI Reasoning**: "Master-level skill? Weeks or months of work? → Gold"

### Category 5: Services (Direct Labor Pricing)

Services are pure labor — price equals time directly.

| Service | Price | Labor Reality |
|---------|-------|---------------|
| Unskilled labor (day) | 5-10c | Moving things, digging, carrying |
| Skilled labor (day) | 2-3s | Carpentry, masonry, cooking |
| Expert service (day) | 5-10s | Healing, legal advice, tutoring |
| Hired guard (day) | 3-5s | Skilled + danger premium |
| Guide through wilderness | 1s/day | Local knowledge + time |

**AI Reasoning**: "How long does the service take? What skill level? Any danger premium?"

---

## Weight and Encumbrance

| Coin Load | Approximate Weight | Effect |
|-----------|-------------------|--------|
| Light (< 100 coins) | < 2 lbs | No effect |
| Moderate (100-300 coins) | 2-6 lbs | Noticeable jingle |
| Heavy (300-500 coins) | 6-10 lbs | Slows movement slightly |
| Encumbered (500+ coins) | 10+ lbs | Obvious burden, noise |

---

## Starting Wealth Budget System

Starting wealth uses a **budget-first model**: each social class has a total wealth budget (in copper). At character creation, the AI generates equipment with copper prices. At session start, equipment value is subtracted from the budget and the remainder becomes liquid coins.

### Total Wealth Budgets

| Social Status | Total Budget | Budget (copper) | Example Breakdown |
|---------------|-------------|-----------------|-------------------|
| Nobility | 52g | 26,000c | Noble outfit 2g + fine sword 3g + horse 15g + 26g liquid |
| Gentry | 11g 20s | 5,700c | Good sword 1g + quality boots 15s + comfortable savings |
| Merchant | 8g | 4,000c | Trade goods + working capital |
| Commoner | 1g | 500c | Dagger 10s + basic clothes + a few coppers |
| Underclass | 0g 0s 50c | 50c | Ragged clothes + a rusty knife |

### How It Works

1. **Character generation**: AI generates equipment as objects with `copperValue` and `category`
2. **Session start**: `sumEquipmentValue()` totals all equipment copper values
3. **Remaining coins**: `calculateStartingCoins(status, equipmentValue)` subtracts from budget
4. **Clamp to zero**: If equipment exceeds budget, character starts with 0 coins but keeps gear

### Formula

```
Starting Coins = fromCopper(max(0, TOTAL_WEALTH_BUDGET[status] - equipmentValue))
```

This creates natural economic tension: a commoner who starts with a sword (500c) has almost no spending money left.

---

## Starting Wealth (Legacy Fallback)

For sessions without priced equipment, the legacy `STARTING_WEALTH` table provides max liquid coins:

| Social Status | Starting Coins | Reasoning |
|---------------|----------------|-----------|
| Nobility | 50g, 100s, 0c | Liquid funds; actual wealth in land |
| Gentry | 10g, 50s, 200c | Comfortable but working |
| Merchant | 5g, 100s, 500c | Working capital |
| Commoner | 0g, 20s, 300c | Months of savings |
| Underclass | 0g, 0s, 50c | Hand-to-mouth existence |

---

## Quick Reference for AI

### Coppers (Passive/Bulk)
Ale 2c, Bread 1c, Candle 1c, Cheese 3c, Common meal 5c, Eggs 2c

### Silvers (Crafted/Harvested)
Dagger 10s, Good boots 15s, Private room 3s/night, Iron pot 8s, Common wine 15c

### Gold (Master Work)
Sword 1g, Leather armor 2g, Horse 15g, Chainmail 15g, Plate 100g

### Transaction Rules
1. State EXACT amounts: "You pay 3 silver and 15 copper"
2. Include in state_changes: `coins: -3s-15c (ale and bread)`
3. If player lacks funds, narrate the problem naturally

---

## World Items

Items can exist independently in the game world, keyed by location. This enables dropping gear, finding loot, being robbed, or forgetting items at a location.

### State Change Format

```text
world_item: +1 Iron Dagger (pack)           → places item at current location
world_item: -1 Iron Dagger (pack)           → removes item from current location
```

### Transfers

Moving items between the player and the world uses **paired** state_changes in a single response:

| Action | state_changes |
|---|---|
| **Pick up** | `world_item: -1 Arrow (consumable)` + `inventory: +1 Arrow (consumable)` |
| **Drop** | `inventory: -1 Sword (equipped)` + `world_item: +1 Sword (equipped)` |
| **Robbery** | Multiple `inventory: -1 ...` + `world_item: +1 ...` at a different location |

### Persistence

World items are stored in `session_state.worldItems`, keyed by `locationId`. They persist across scenes at that location — if a player drops a map at an inn, it will be there when they return.
