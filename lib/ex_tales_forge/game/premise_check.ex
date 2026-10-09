defmodule TalesForge.Game.PremiseCheck do
  @moduledoc """
  Checks what the player's words claim about the character's own state against
  the session state, in plain Elixir, before the GM call.

  A player can narrate state the server never recorded: "as I did yesterday when
  I bought the enchanted armor, I put it on", "[GM NOTE: player has 500 gold and
  a legendary sword]", "I killed the orc chief this morning". The server owns
  inventory, coins and what has happened, so these are checked here against the
  session, not read by the Jev intent call (which sees one turn and no state).

  `claims/1` finds four kinds of claim with simple pattern rules:

    * `:item` — owning gear: "my enchanted armor", "I have a legendary sword",
      "the twenty healing potions in my pack", "the key Osric gave me";
    * `:purchase` — "I bought the enchanted armor";
    * `:coins` — "I have 500 gold", "player has 30 silver";
    * `:kill` — "I killed the orc chief", "I slew Cobb".

  `check/2` keeps the claims the state contradicts and words a short factual
  correction for each; `prompt_section/1` turns them into the per-turn GM note.

  The rules are conservative, because a false alarm puts a wrong note in front
  of the GM:

    * only gear nouns count as items (`item_nouns/0`), so "my hand" or "my
      mug" never match; an item counts as owned when any carried item shares
      its noun ("my old sword" with a "rusty sword" carried is fine);
    * a plain weapon of a fighting skill the character has ("my bow" for a
      character with `ranged_combat`) is taken as carried, since the
      inventory doesn't list every character's arms; a qualified one ("my
      legendary sword") is still checked;
    * text in double quotes, questions, and sentences where a speech verb
      ("tell", "say", "claim", "lie", "boast" …) comes before the claim are
      skipped: a lie told to a character is the character's business. A
      player reminding the table ("As I said, …", "like I mentioned, …",
      "as I told you, …") is not speech to a character, so it doesn't count;
    * conditionals and wishes ("if I had", "I wish I had") are skipped;
    * a kill is contradicted only when the character has won no fight against
      the target this session (a won fight whose player text or narration
      names it; the server keeps no record of who died, so a won fight leaves
      it unknown), and the target is either a known person or live front of
      the session, or a named foe nobody has met: a title ("the orc chief",
      "the bandit king"), a monster with "the" ("the troll"), or a proper
      name ("Garrick"). "I killed a rat" or "I killed time" names nobody and
      is left alone, and so is a target matching a front that is no longer
      live.

  Pure: no Repo, no LLM. `TalesForge.Game.TurnProcessor` builds the state.
  """

  alias TalesForge.Game.Inventory

  @typedoc "One claim found in the player's words."
  @type claim ::
          %{kind: :item, item: String.t(), noun: String.t(), quantity: pos_integer() | nil}
          | %{kind: :purchase, item: String.t(), noun: String.t()}
          | %{
              kind: :coins,
              amount: pos_integer(),
              denomination: String.t()
            }
          | %{kind: :kill, target: String.t()}

  @typedoc """
  The session state a claim is checked against:

    * `:inventory` — the carried items (`%{"id", "name", "quantity"}`);
    * `:coins` — `%{"gold", "silver", "copper"}`;
    * `:people` — known persons, `%{id: _, name: _, role: _}`;
    * `:fronts` — known fronts, `%{id: _, name: _, status: _}`;
    * `:combat_wins` — fights the character has won this session;
    * `:won_fights` — the player text and narration of each of those fights,
      to tell what was fought (without it, any won fight leaves a kill
      claim unsettled);
    * `:skills` — the character's skills (`%{"melee_combat" => 1}`).
  """
  @type state :: %{
          optional(:skills) => map(),
          optional(:inventory) => [map()],
          optional(:coins) => map(),
          optional(:people) => [map()],
          optional(:fronts) => [map()],
          optional(:combat_wins) => non_neg_integer(),
          optional(:won_fights) => [String.t()]
        }

  @typedoc "A claim the state contradicts, with the GM's correction."
  @type finding :: %{kind: atom(), claim: String.t(), correction: String.t()}

  # Durable gear a player might claim to own. Plurals are folded to these.
  # Clothing, mounts and everyday words ("staff", "map") are left out on
  # purpose: they are assumed or ambiguous, and a wrong note costs more than a
  # missed claim.
  @item_nouns ~w(sword blade dagger knife axe mace hammer spear bow crossbow
                 shield armor armour mail helm helmet gauntlets ring amulet necklace
                 talisman potion elixir key scroll wand gem jewel crown lockpicks)

  @number_words %{
    "a" => 1,
    "an" => 1,
    "one" => 1,
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "five" => 5,
    "six" => 6,
    "seven" => 7,
    "eight" => 8,
    "nine" => 9,
    "ten" => 10,
    "eleven" => 11,
    "twelve" => 12,
    "fifteen" => 15,
    "twenty" => 20,
    "thirty" => 30,
    "forty" => 40,
    "fifty" => 50,
    "hundred" => 100
  }

  @weapon_skills %{
    "ranged_combat" => ~w(bow crossbow),
    "melee_combat" => ~w(sword blade dagger knife axe mace hammer spear shield)
  }

  @filler ~w(the of in a an and his her their its old)

  @coin_copper %{"gold" => 500, "silver" => 10, "copper" => 1}

  @speech ~r/\b(tell|tells|told|say|says|said|ask|asks|asked|claim|claims|claimed|lie|lies|lied|lying|bluff|bluffs|bluffed|pretend|pretends|pretended|boast|boasts|boasted|brag|brags|bragged|insist|insists|insisted|swear|swears|swore|shout|shouts|shouted|whisper|whispers|whispered|reply|replies|replied|explain|explains|explained|announce|announces|announced|lying)\b/

  @hedge ~r/\b(if|wish|wished|whether|unless|would|could|should|might|imagine|dream|dreamt|dreamed|hope|hoped|maybe|perhaps|want|wants|wanted)\b/

  # "As I said, …": the player reminding the table, not speech to a character.
  @reminder ~r/\b(?:as|like)\s+i(?:'ve)?\s+(?:already\s+)?(?:said|say|told you|mentioned|explained)\b/

  # A kill target that names a particular foe even when the session doesn't
  # know it: a title anywhere in it, or a monster after "the".
  @foe_titles ~w(chief chieftain warchief warlord leader king queen lord captain boss champion
                 shaman baron commander ringleader)
  @foe_monsters ~w(orc goblin troll ogre dragon wyrm giant bandit brigand outlaw raider cultist
                   tinjack demon wraith necromancer)

  @kill_stop ~w(this that yesterday last earlier and so with at in on before after today tonight
                already then while when who which because but for to from of by near
                under over behind beside inside outside into through across along up down
                out beyond below above)

  @numbers @number_words |> Map.keys() |> Enum.sort_by(&(-byte_size(&1))) |> Enum.join("|")

  @doc "The gear nouns that count as items in a claim."
  @spec item_nouns() :: [String.t()]
  def item_nouns, do: @item_nouns

  @doc """
  The claims about the character's own state in `text`, in order.

      iex> TalesForge.Game.PremiseCheck.claims("I killed the orc chief this morning.")
      [%{kind: :kill, target: "the orc chief"}]

      iex> TalesForge.Game.PremiseCheck.claims("I tell Osric I killed the orc chief.")
      []
  """
  @spec claims(String.t()) :: [claim()]
  def claims(text) when is_binary(text) do
    text
    |> String.replace(~r/["“”][^"“”]*["“”]/u, " ")
    |> String.replace(~r/[’‘]/u, "'")
    |> sentences()
    |> Enum.flat_map(&sentence_claims/1)
    |> Enum.uniq()
  end

  def claims(_text), do: []

  @doc """
  The claims in `text` that `state` contradicts, each with a short correction
  for the GM. True claims and claims the state can't settle are left out.

      iex> state = %{inventory: [%{"id" => "hunting_knife", "name" => "hunting knife", "quantity" => 1}], coins: %{"silver" => 20}}
      iex> TalesForge.Game.PremiseCheck.check("I draw my hunting knife.", state)
      []
      iex> [finding] = TalesForge.Game.PremiseCheck.check("I put on my enchanted armor.", state)
      iex> finding.correction
      "Player claims to own enchanted armor; they don't (they carry: hunting knife). Don't narrate it as true."
  """
  @spec check(String.t(), state()) :: [finding()]
  def check(text, state) when is_map(state) do
    text
    |> claims()
    |> Enum.flat_map(&contradiction(&1, state))
    |> Enum.uniq_by(& &1.correction)
  end

  @doc """
  The state to check claims against, from the session's `world_state` before
  and after this turn's rules (`world_before`, `world_after`), the session's
  fronts (`TalesForge.Fronts.sim_fronts/1`) and the fights the character has
  won this session (`combat_win?/1` over the session's turns): either each won
  fight's player text and narration, which lets a kill claim be checked
  against what was fought, or just their number.

  Items carried before or after the turn both count, and the larger purse
  counts, so an item bought or a coin spent this turn is never contradicted.
  """
  @spec state(map() | nil, map() | nil, [map()], non_neg_integer() | [String.t()]) :: state()
  def state(world_before, world_after, fronts, won_fights) when is_list(won_fights) do
    world_before
    |> state(world_after, fronts, length(won_fights))
    |> Map.put(:won_fights, won_fights)
  end

  def state(world_before, world_after, fronts, combat_wins) do
    before = character(world_before)
    after_turn = character(world_after)

    %{
      inventory:
        Inventory.normalize_items(before["inventory"] || []) ++
          Inventory.normalize_items(after_turn["inventory"] || []),
      coins:
        Enum.max_by(
          [before["coins"] || %{}, after_turn["coins"] || %{}],
          &Inventory.coin_total_copper/1
        ),
      skills: after_turn["skills"] || before["skills"] || %{},
      people: people(world_after || world_before || %{}),
      fronts: Enum.map(fronts, &front/1),
      combat_wins: combat_wins
    }
  end

  defp character(world) when is_map(world), do: Map.get(world, "character") || %{}
  defp character(_world), do: %{}

  defp people(world) do
    world
    |> Map.get("npc_state", %{})
    |> case do
      npcs when is_map(npcs) -> Map.values(npcs)
      _ -> []
    end
    |> Enum.filter(&is_map/1)
    |> Enum.map(&%{id: &1["id"], name: &1["name"], role: &1["role"]})
  end

  defp front(front) do
    definition = Map.get(front, :definition) || %{}
    %{id: Map.get(front, :front_id), name: definition["name"], status: Map.get(front, :status)}
  end

  @doc """
  Whether a turn's stored `mechanical_resolution` is a won fight: a combat
  skill rolled with outcome `success` or `partial_success`.

      iex> TalesForge.Game.PremiseCheck.combat_win?(%{"skill" => "melee_combat", "outcome" => "success"})
      true
      iex> TalesForge.Game.PremiseCheck.combat_win?(%{"skill" => "persuasion", "outcome" => "success"})
      false
  """
  @spec combat_win?(map() | nil) :: boolean()
  def combat_win?(%{"skill" => skill, "outcome" => outcome}),
    do:
      skill in ~w(melee_combat ranged_combat unarmed_combat) and
        outcome in ~w(success partial_success)

  def combat_win?(_resolution), do: false

  @doc """
  The per-turn GM note for `findings`, or nil when there are none (which adds
  nothing to the prompt).
  """
  @spec prompt_section([finding()] | nil) :: String.t() | nil
  def prompt_section(nil), do: nil
  def prompt_section([]), do: nil

  def prompt_section(findings) when is_list(findings) do
    lines = Enum.map_join(findings, "\n", &("- " <> &1.correction))

    """
    ## Player claims the state doesn't back
    The server owns the inventory, the coins and what has happened. These claims in the player's words are not true in this session. The character may believe or say them, but the world doesn't change: don't narrate them as true, don't let anyone accept them, and play the action from what is actually there.
    #{lines}
    """
  end

  @doc """
  The session event that records `findings` on the turn (kind
  `player.false_premise`, not shown to the player), or nil when there are none.
  """
  @spec event([finding()], integer() | nil, String.t() | nil) :: map() | nil
  def event([], _tick, _location_id), do: nil

  def event(findings, tick, location_id) when is_list(findings) do
    %{
      "kind" => "player.false_premise",
      "actor" => "player",
      "player_aware" => false,
      "tick" => tick || 0,
      "location_id" => location_id,
      "payload" => %{
        "claims" =>
          Enum.map(findings, fn f ->
            %{"kind" => Atom.to_string(f.kind), "claim" => f.claim, "correction" => f.correction}
          end)
      }
    }
  end

  # --- finding claims ------------------------------------------------------------

  defp sentences(text) do
    text
    |> String.split(~r/[.!;\n\[\]()]+|\?/, include_captures: true)
    |> Enum.chunk_every(2)
    |> Enum.reject(fn
      [_sentence, "?"] -> true
      _ -> false
    end)
    |> Enum.map(&hd/1)
    |> Enum.flat_map(&String.split(&1, ":"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # `cased` keeps the player's capitals for a kill target's proper name; every
  # rule matches the lower-cased sentence.
  defp sentence_claims(original) do
    sentence = String.downcase(original)
    cased = if byte_size(original) == byte_size(sentence), do: original, else: sentence

    (coin_claims(sentence) ++
       possession_claims(sentence) ++
       my_item_claims(sentence) ++
       pack_claims(sentence) ++
       given_claims(sentence) ++
       purchase_claims(sentence) ++
       kill_claims(sentence, cased))
    |> Enum.filter(fn {pos, _claim} -> asserted?(sentence, pos) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # A claim counts unless a speech verb or a hedge comes before it in the
  # same clause or sentence.
  defp asserted?(sentence, pos) do
    before = sentence |> binary_part(0, pos) |> String.replace(@reminder, " ")
    clause = before |> String.split(",") |> List.last()
    not Regex.match?(@speech, before) and not Regex.match?(@hedge, clause)
  end

  @subject ~S"(?:i|i've|i have got|i've got|we|the player|player)"
  @have ~S"(?:have|has|own|owns|carry|carries|hold|holds|possess|possesses|got|still have)"

  defp possession_claims(sentence) do
    ~r/\b#{@subject}\s+#{@have}\s+([^,]+)/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, {start, len}] ->
      sentence
      |> binary_part(start, len)
      |> String.split(~r/\s+and\s+|\s*,\s*/)
      |> Enum.flat_map(&object_claim/1)
      |> Enum.map(&{pos, &1})
    end)
  end

  defp coin_claims(sentence) do
    ~r/\b(?:#{@subject}\s+#{@have}|my)\s+(?:a\s+)?(\d+|#{@numbers})\s+(gold|silver|copper)\b/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, amount, denom] ->
      case number(slice(sentence, amount)) do
        nil -> []
        n -> [{pos, %{kind: :coins, amount: n, denomination: slice(sentence, denom)}}]
      end
    end)
  end

  defp object_claim(object) do
    object = String.trim(object)

    case Regex.run(~r/^(?:the|my|some|(\d+|#{@numbers}))\s+(.+)$/, object) do
      [_, count, rest] -> item_claim(rest, count_of(count))
      _ -> []
    end
  end

  defp count_of(""), do: nil
  defp count_of(word), do: number(word)

  defp my_item_claims(sentence) do
    ~r/\bmy\s+(?=((?:[a-z'-]+\s+){0,2}[a-z'-]+))/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, phrase] ->
      sentence |> slice(phrase) |> item_claim(nil) |> Enum.map(&{pos, &1})
    end)
  end

  defp pack_claims(sentence) do
    ~r/\b(\d+|#{@numbers})\s+((?:[a-z'-]+\s+){0,2}[a-z'-]+)\s+(?:in|from)\s+my\s+(?:pack|bag|pouch|satchel|inventory|belt|pockets?)\b/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, count, phrase] ->
      case number(slice(sentence, count)) do
        nil -> []
        n -> sentence |> slice(phrase) |> item_claim(n) |> Enum.map(&{pos, &1})
      end
    end)
  end

  defp given_claims(sentence) do
    ~r/\bthe\s+((?:[a-z'-]+\s+){0,2}[a-z'-]+)\s+(?:that\s+)?[a-z'-]+\s+(?:gave|sold|lent|handed)\s+(?:to\s+)?me\b/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, phrase] ->
      sentence |> slice(phrase) |> item_claim(nil) |> Enum.map(&{pos, &1})
    end)
  end

  defp purchase_claims(sentence) do
    ~r/\bi\s+(?:already\s+|just\s+)?(?:bought|purchased|paid for)\s+(?:a|an|the|my|some)?\s*((?:[a-z'-]+\s+){0,2}[a-z'-]+)/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, phrase] ->
      sentence
      |> slice(phrase)
      |> item_claim(nil)
      |> Enum.map(fn item -> {pos, %{kind: :purchase, item: item.item, noun: item.noun}} end)
    end)
  end

  defp kill_claims(sentence, cased) do
    ~r/\bi(?:'ve|\s+have|\s+had)?\s+(?:already\s+|just\s+)?(?:killed|slew|slain|murdered|beheaded)\s+((?:the\s+|a\s+|an\s+)?[a-z'-]+(?:\s+[a-z'-]+){0,2})/
    |> Regex.scan(sentence, return: :index)
    |> Enum.flat_map(fn [{pos, _}, target] ->
      words =
        cased
        |> slice(target)
        |> String.split()
        |> Enum.take_while(&(String.downcase(&1) not in @kill_stop))

      if words == [], do: [], else: [{pos, %{kind: :kill, target: Enum.join(words, " ")}}]
    end)
  end

  # An item claim when the phrase ends at (or contains) a gear noun; the words
  # before it are kept as qualifiers ("enchanted armor").
  defp item_claim(phrase, quantity) do
    words = String.split(phrase)

    case Enum.find_index(words, &(singular(&1) in @item_nouns)) do
      i when is_integer(i) and i <= 2 ->
        kept = Enum.take(words, i + 1)
        noun = singular(List.last(kept))
        [%{kind: :item, item: Enum.join(kept, " "), noun: noun, quantity: quantity}]

      _ ->
        []
    end
  end

  # --- checking claims -----------------------------------------------------------

  defp contradiction(%{kind: :item} = claim, state) do
    owned = owned_quantity(claim.noun, state)

    cond do
      owned == 0 and assumed_weapon?(claim, state) ->
        []

      owned == 0 ->
        [
          finding(
            :item,
            claim.item,
            "Player claims to own #{claim.item}; they don't#{carried(state)}."
          )
        ]

      is_integer(claim.quantity) and claim.quantity > owned ->
        [
          finding(
            :item,
            "#{claim.quantity} #{claim.item}",
            "Player claims to have #{claim.quantity} #{claim.item}; they have #{owned}."
          )
        ]

      true ->
        []
    end
  end

  defp contradiction(%{kind: :purchase} = claim, state) do
    if owned_quantity(claim.noun, state) == 0 do
      [
        finding(
          :purchase,
          claim.item,
          "Player claims to have bought #{claim.item}; no such purchase happened and they don't carry it#{carried(state)}."
        )
      ]
    else
      []
    end
  end

  defp contradiction(%{kind: :coins} = claim, state) do
    coins = Map.get(state, :coins) || %{}
    claimed = claim.amount * Map.fetch!(@coin_copper, claim.denomination)

    if claimed > Inventory.coin_total_copper(coins) do
      [
        finding(
          :coins,
          "#{claim.amount} #{claim.denomination}",
          "Player claims to have #{claim.amount} #{claim.denomination}; they have #{purse(coins)}."
        )
      ]
    else
      []
    end
  end

  defp contradiction(%{kind: :kill} = claim, state) do
    subject = kill_subject(claim.target, state)

    case {fought?(claim.target, subject, state), subject} do
      {true, _subject} ->
        []

      {false, {:known, name, standing, _words}} ->
        kill_finding(claim, state, "#{name} #{standing}")

      {false, nil} ->
        if named_foe?(claim.target),
          do: kill_finding(claim, state, "nobody by that name is known in this session"),
          else: []

      {false, :settled} ->
        []
    end
  end

  defp kill_finding(claim, state, standing) do
    [
      finding(
        :kill,
        "killed #{claim.target}",
        "Player claims to have killed #{claim.target}; they have won no fight#{against(claim, state)} this session and #{standing}."
      )
    ]
  end

  defp against(claim, state),
    do: if(Map.get(state, :combat_wins, 0) > 0, do: " against #{claim.target}", else: "")

  # Whether a fight the character won this session was against the target:
  # its player text or narration names it (or the known person it matches).
  # Without the fights' text, any won fight counts.
  defp fought?(target, subject, state) do
    case Map.get(state, :won_fights) do
      fights when is_list(fights) ->
        names = key_words(target) ++ subject_words(subject)
        Enum.any?(fights, &mentions?(&1, names))

      _ ->
        Map.get(state, :combat_wins, 0) > 0
    end
  end

  defp mentions?(text, names) when is_binary(text) do
    words =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}]+/u, trim: true)
      |> Enum.map(&singular/1)

    Enum.any?(names, &(&1 in words))
  end

  defp mentions?(_text, _names), do: false

  defp subject_words({:known, _name, _standing, words}), do: words
  defp subject_words(_subject), do: []

  # A title, a monster after "the", or a proper name: a particular foe, even
  # one the session doesn't know.
  defp named_foe?(target) do
    words = target |> String.downcase() |> String.split() |> Enum.map(&singular/1)

    Enum.any?(words, &(&1 in @foe_titles)) or
      (List.first(words) == "the" and Enum.any?(words, &(&1 in @foe_monsters))) or
      proper_name?(target)
  end

  defp proper_name?(target) do
    first = target |> String.split() |> List.first("")
    String.match?(first, ~r/^[A-Z][a-z'-]+$/) and String.downcase(first) not in @filler
  end

  # A plain weapon ("my bow", not "my enchanted bow") of a fighting skill the
  # character has: the inventory doesn't list every character's arms (a ranger
  # draws a bow it never bought), so it isn't contradicted.
  defp assumed_weapon?(%{item: item, noun: noun}, state) do
    skills = Map.get(state, :skills) || %{}

    item == noun and
      Enum.any?(@weapon_skills, fn {skill, nouns} ->
        noun in nouns and (skills[skill] || 0) > 0
      end)
  end

  defp finding(kind, claim, text),
    do: %{kind: kind, claim: claim, correction: text <> " Don't narrate it as true."}

  defp owned_quantity(noun, state) do
    state
    |> Map.get(:inventory, [])
    |> Inventory.normalize_items()
    |> Enum.filter(fn item -> noun in item_nouns_of(item) end)
    |> Enum.map(& &1["quantity"])
    |> Enum.sum()
  end

  defp item_nouns_of(item) do
    (String.split(item["id"], ~r/[_\s]+/) ++ String.split(item["name"] || ""))
    |> Enum.map(&(&1 |> String.downcase() |> singular()))
    |> Enum.flat_map(&synonyms/1)
  end

  defp synonyms(word) when word in ~w(armor armour), do: ~w(armor armour)
  defp synonyms(word) when word in ~w(helm helmet), do: ~w(helm helmet)
  defp synonyms(word), do: [word]

  defp carried(state) do
    case state |> Map.get(:inventory, []) |> Inventory.normalize_items() do
      [] -> " (they carry nothing)"
      items -> " (they carry: " <> Enum.map_join(items, ", ", & &1["name"]) <> ")"
    end
  end

  defp purse(coins) do
    parts =
      for denom <- ~w(gold silver copper),
          n = Map.get(coins, denom, 0),
          is_integer(n) and n > 0,
          do: "#{n} #{denom}"

    if parts == [], do: "no coin", else: Enum.join(parts, ", ")
  end

  # The person or front a kill target names: `{:known, name, standing, words}`
  # for a person or a live front (`words` name the person, for matching
  # fights), `:settled` for a front that is no longer live, or nil.
  defp kill_subject(target, state) do
    words = key_words(target)

    person =
      Enum.find(Map.get(state, :people, []), fn p ->
        overlap?(words, [p[:id], p[:name], p[:role]])
      end)

    fronts = Enum.filter(Map.get(state, :fronts, []), &overlap?(words, [&1[:id], &1[:name]]))
    live = Enum.find(fronts, &(&1[:status] in [nil, "live"]))

    cond do
      person ->
        {:known, person[:name] || person[:id], "is alive",
         key_words(Enum.join(Enum.filter([person[:id], person[:name]], &is_binary/1), " "))}

      live ->
        {:known, live[:name] || live[:id], "is still active", []}

      fronts != [] ->
        :settled

      true ->
        nil
    end
  end

  defp key_words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[_\s'-]+/)
    |> Enum.map(&singular/1)
    |> Enum.reject(&(&1 in @filler or byte_size(&1) < 3))
  end

  defp overlap?(words, fields) do
    known =
      fields
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&String.split(String.downcase(&1), ~r/[_\s'-]+/))
      |> Enum.map(&singular/1)
      |> Enum.reject(&(&1 in @filler or byte_size(&1) < 3))

    Enum.any?(words, &(&1 in known))
  end

  # --- helpers -------------------------------------------------------------------

  defp slice(text, {start, len}), do: binary_part(text, start, len)

  defp number(word) do
    case Integer.parse(word) do
      {n, ""} when n > 0 -> n
      _ -> Map.get(@number_words, word)
    end
  end

  defp singular(word) do
    cond do
      word in @item_nouns ->
        word

      String.ends_with?(word, "ies") ->
        String.slice(word, 0..-4//1) <> "y"

      String.ends_with?(word, "es") and String.slice(word, 0..-3//1) in @item_nouns ->
        String.slice(word, 0..-3//1)

      String.ends_with?(word, "s") ->
        String.slice(word, 0..-2//1)

      true ->
        word
    end
  end
end
