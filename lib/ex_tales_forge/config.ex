defmodule TalesForge.Config do
  @moduledoc """
  Runtime configuration loaded from environment variables.
  """

  def llm_provider do
    case blank_to_nil(System.get_env("LLM_PROVIDER")) do
      nil -> auto_provider()
      value -> String.downcase(value)
    end
  end

  def xai_api_key, do: System.get_env("XAI_API_KEY", "")
  def openai_api_key, do: System.get_env("OPENAI_API_KEY", "")
  def anthropic_api_key, do: System.get_env("ANTHROPIC_API_KEY", "")
  @default_xai_model "grok-4.20-0309-non-reasoning"

  def xai_model, do: System.get_env("XAI_MODEL", @default_xai_model)
  def default_xai_model, do: @default_xai_model

  def tier1_model, do: blank_to_nil(System.get_env("TIER1_MODEL"))
  def tier2_model, do: blank_to_nil(System.get_env("TIER2_MODEL"))

  def tier1_temperature, do: env_float("TIER1_TEMPERATURE", 0.0)
  def tier2_temperature, do: env_float("TIER2_TEMPERATURE", 0.7)
  def tier1_confidence_threshold, do: env_float("TIER1_CONFIDENCE_THRESHOLD", 0.75)
  def tier1_max_tokens, do: env_int("TIER1_MAX_TOKENS", 400)
  def tier2_max_tokens, do: env_int("TIER2_MAX_TOKENS", 700)

  @doc """
  True when persona runs may start here: `PLAYTEST_RUNNER_ENABLED` is "true"
  and this is not the production app (playtest runs live only on playtest;
  `TalesForge.AppRole`). Persona runs, series and scoring use the same gate.
  """
  @spec playtest_runner?() :: boolean()
  def playtest_runner? do
    Application.get_env(:ex_tales_forge, :playtest_runner_enabled, false) == true and
      TalesForge.AppRole.here?(:playtest_runs)
  end

  @doc """
  The Jev intent mode new default-variant sessions get (`INTENT_JEV`, read in
  `config/runtime.exs`): `:off` (today's intent path), `:shadow` (today's path
  plays; the Jev intent read runs alongside and is only logged) or `:on` (the
  Jev intent read drives the turn). Default `:off`. See `TalesForge.IntentJev`.
  """
  @spec intent_jev_mode() :: :off | :shadow | :on
  def intent_jev_mode, do: Application.get_env(:ex_tales_forge, :intent_jev, :off)

  @doc "Jev intent: the confidence at or above which the turn acts on the top reading (`INTENT_ACT_MIN_CONFIDENCE`, default 0.70)."
  @spec intent_act_min_confidence() :: float()
  def intent_act_min_confidence,
    do: Application.get_env(:ex_tales_forge, :intent_act_min_confidence, 0.70)

  @doc "Jev intent: the confidence below which the turn may ask the player (`INTENT_ASK_BELOW_CONFIDENCE`, default 0.45)."
  @spec intent_ask_below_confidence() :: float()
  def intent_ask_below_confidence,
    do: Application.get_env(:ex_tales_forge, :intent_ask_below_confidence, 0.45)

  @doc """
  Jev intent: the raw (uncalibrated) confidence below which the turn may ask the
  player, when the top two readings play out differently
  (`INTENT_ASK_BELOW_RAW_CONFIDENCE`, default 0.45; 0 turns the raw check off).
  """
  @spec intent_ask_below_raw_confidence() :: float()
  def intent_ask_below_raw_confidence,
    do: Application.get_env(:ex_tales_forge, :intent_ask_below_raw_confidence, 0.45)

  @doc "Jev intent: the call's receive timeout in ms on the player's clock (`INTENT_JEV_TIMEOUT_MS`, default 1500)."
  @spec intent_jev_timeout_ms() :: pos_integer()
  def intent_jev_timeout_ms,
    do: Application.get_env(:ex_tales_forge, :intent_jev_timeout_ms, 1_500)

  @doc "The minimum `benign` safety confidence for the GM to get the player's own words (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`, default 0.90)."
  @spec player_quote_min_benign_confidence() :: float()
  def player_quote_min_benign_confidence,
    do: Application.get_env(:ex_tales_forge, :player_quote_min_benign_confidence, 0.90)

  @doc """
  The minimum "GM thinking" pause before the streamed narration shows, in ms
  (`GM_MIN_DELAY_MS`, default 1500). The play page's typing dots fill it
  (docs/design-gm-streaming.md).
  """
  @spec gm_min_delay_ms() :: integer()
  def gm_min_delay_ms, do: env_int("GM_MIN_DELAY_MS", 1500)

  @doc """
  The slowest the streamed narration is revealed, in ms per character
  (`GM_REVEAL_MIN_MS_PER_CHAR`, default 8). A larger backlog reveals faster,
  so the text never lags its arrival by more than about 250 ms
  (docs/design-gm-streaming.md).
  """
  @spec gm_reveal_min_ms_per_char() :: integer()
  def gm_reveal_min_ms_per_char, do: env_int("GM_REVEAL_MIN_MS_PER_CHAR", 8)

  @doc "NPC reaction prototype (Jev, before the GM call): NPC_REACTIONS=on. Default off."
  def npc_reactions?, do: on?("NPC_REACTIONS")

  @doc "Per-NPC Jev reaction timeout (ms); on timeout the turn goes on without that reaction."
  def npc_reactions_timeout_ms, do: env_int("NPC_REACTIONS_TIMEOUT_MS", 600)

  @doc """
  Turn pipeline step 5: the Jev intent read uses catalogue v2
  (`TalesForge.Game.JevIntent`): `rest`, `work`, `equip`, `give` and
  `none_fits`, up to 3 ordered actions this turn, and the manner.
  JEV_CATALOGUE_V2=on. Default off.
  """
  @spec jev_catalogue_v2?() :: boolean()
  def jev_catalogue_v2?, do: on?("JEV_CATALOGUE_V2")

  @doc """
  Turn pipeline PR 1: the outcome record of each turn goes to the per-turn GM
  prompt and to the turn (`TalesForge.Game.OutcomeRecord`):
  TURN_OUTCOME_RECORD=on. Default off.
  """
  @spec turn_outcome_record?() :: boolean()
  def turn_outcome_record?, do: on?("TURN_OUTCOME_RECORD")

  @doc """
  The skill sets how much the character notices (`TalesForge.Game.Notice`):
  the GM prompt gets the detail level and 0-2 true details from the world
  state. SKILL_DETAIL_LEVEL=on. Default off.
  """
  @spec skill_detail_level?() :: boolean()
  def skill_detail_level?, do: on?("SKILL_DETAIL_LEVEL")

  @doc """
  Skill split (`TalesForge.Game.SkillSplit`): a player splits one skill action
  into two or three parts, and the server rolls each part. SKILL_SPLIT=on.
  Default off. With the flag off, the prompts and the rolls do not change.
  """
  @spec skill_split?() :: boolean()
  def skill_split?, do: on?("SKILL_SPLIT")

  @doc """
  Self-check (`TalesForge.Game.Turn.SelfCheck`): Jev also reads whether the
  player asks about their own coins or pack, and the GM answers as the
  narrator from the sheet. JEV_SELF_CHECK=on. Default off. With the flag off,
  the Jev request, the prompts and the turns do not change.
  """
  @spec jev_self_check?() :: boolean()
  def jev_self_check?, do: on?("JEV_SELF_CHECK")

  @doc """
  Jev clarify bands v2 (`TalesForge.Game.IntentClarification.defaults/1`):
  act_min 0.80, ask_below 0.45, raw ask_below 0.30, runner_up 0.40.
  JEV_CLARIFY_V2=on. Default off on prod and eval. With the flag off, the
  bands stay at today's 0.70 / 0.45 / 0.45 / 0.25. Turning this on in
  production is a founder decision after merge; it is not set in fly.toml.
  """
  @spec jev_clarify_v2?() :: boolean()
  def jev_clarify_v2?, do: on?("JEV_CLARIFY_V2")

  @doc """
  The skill split thresholds (d100 scale): `start`, `triple` and
  `min_uneven_part`, from `config :ex_tales_forge, :skill_split`.
  """
  @spec skill_split_settings() :: %{
          start: pos_integer(),
          triple: pos_integer(),
          min_uneven_part: pos_integer()
        }
  def skill_split_settings do
    settings = Application.get_env(:ex_tales_forge, :skill_split, [])

    %{
      start: Keyword.get(settings, :start, 100),
      triple: Keyword.get(settings, :triple, 150),
      min_uneven_part: Keyword.get(settings, :min_uneven_part, 25)
    }
  end

  @doc """
  Turn pipeline PR 2: the premise check runs first, before the mechanics and
  the NPCs. A claim that the state contradicts blocks the action
  (`TalesForge.Game.TurnProcessor`): TURN_PREMISE_FIRST=on. Default off.
  """
  @spec turn_premise_first?() :: boolean()
  def turn_premise_first?, do: on?("TURN_PREMISE_FIRST")

  @doc """
  Locations step 1 (docs/design-locations.md): the GM prompt gets what the
  character sees on its place's grid. LOCATION_GRID=on. Default off.
  """
  @spec location_grid?() :: boolean()
  def location_grid?, do: on?("LOCATION_GRID")

  @doc """
  Turn pipeline step 7 (bug h-fa06): an injection turn plays no action, and
  the history keeps a placeholder, not the injected text
  (`TalesForge.Game.HistoryStrip`): HISTORY_STRIP_INJECTION=on. Default off.
  """
  @spec history_strip_injection?() :: boolean()
  def history_strip_injection?,
    do: on?("HISTORY_STRIP_INJECTION")

  @doc """
  Turn pipeline step 4: NPC dialogue memory and the repetition guard
  (`TalesForge.Game.DialogueMemory`). The premise check runs before the NPC
  reactions, and the NPCs get its findings: NPC_DIALOGUE_MEMORY=on.
  Default off.
  """
  @spec npc_dialogue_memory?() :: boolean()
  def npc_dialogue_memory?,
    do: on?("NPC_DIALOGUE_MEMORY")

  @doc """
  NPCs know a first meeting (board card 84e11f16): each present NPC in the GM
  prompt is marked first meeting or has met (`TalesForge.Game.FirstMeeting`),
  and the GM gets the first-meeting rule. Default on, in every app (founder
  approval 16 Oct, after the playtest pass). NPC_FIRST_MEETING=off turns it
  off.
  """
  @spec npc_first_meeting?() :: boolean()
  def npc_first_meeting?,
    do: System.get_env("NPC_FIRST_MEETING", "on") not in ~w(off false 0)

  @doc """
  Character memory (board card fc3c9371): at scene end the characters keep
  short-term memories with associations and weights, and the GM prompt
  recalls them by association. CHARACTER_MEMORY=on writes and recalls;
  `shadow` writes the rows and builds the recall but keeps it out of the
  prompt; `off` (default) does nothing.

      iex> TalesForge.Config.character_memory_mode("shadow")
      :shadow
      iex> TalesForge.Config.character_memory_mode("nonsense")
      :off
  """
  @spec character_memory() :: :off | :shadow | :on
  def character_memory, do: character_memory_mode(System.get_env("CHARACTER_MEMORY", "off"))

  @doc false
  @spec character_memory_mode(String.t()) :: :off | :shadow | :on
  def character_memory_mode(value) when value in ~w(on true 1), do: :on
  def character_memory_mode("shadow"), do: :shadow
  def character_memory_mode(_value), do: :off

  @doc """
  Turn pipeline PR 3: coins, items, location and clock come only from stage 3.
  The server runs the prose post-check (`TalesForge.Game.ProseCheck`, log
  only), and rejects a room payment with nobody here who rents rooms:
  TURN_STATE_FROM_MECHANICS=on. Default off.
  """
  @spec turn_state_from_mechanics?() :: boolean()
  def turn_state_from_mechanics?,
    do: on?("TURN_STATE_FROM_MECHANICS")

  @doc """
  Stage 3 applies the outcome of sleep, pay and move to the state
  (`TalesForge.Game.TurnApply`): a payment with no amount uses the coin
  amount in the text or the service price, "pay for a room and go to sleep"
  also plays the sleep, and a move to an unknown place is rejected. It also
  turns on the room-payment rule of `TalesForge.Game.TurnRules`:
  TURN_APPLY_OUTCOMES=on. Default off.
  """
  @spec turn_apply_outcomes?() :: boolean()
  def turn_apply_outcomes?,
    do: on?("TURN_APPLY_OUTCOMES")

  @doc """
  Opposed combat (`TalesForge.Game.Combat`): the player attacks against the
  defender's Parry, the NPC may counterattack, NPCs keep wounds in the
  session, and the GM gets the exchange: COMBAT_OPPOSED=on. Default off.
  """
  @spec combat_opposed?() :: boolean()
  def combat_opposed?,
    do: on?("COMBAT_OPPOSED")

  @doc "World agents prototype (persons/locations hold facts for the GM): WORLD_AGENTS=on. Default off."
  def world_agents?, do: on?("WORLD_AGENTS")

  @doc """
  The places and people around the Valley Inn (`TalesForge.Game.Features`,
  feature `inn_world`): INN_WORLD=on. Read when a session is created. Default off.
  """
  def inn_world?, do: on?("INN_WORLD")

  @doc """
  The Tinjacks antagonist (feature `antagonist`, needs INN_WORLD):
  WORLD_ANTAGONIST=on. Read when a session is created. Default off.
  """
  def world_antagonist?, do: on?("WORLD_ANTAGONIST")

  @doc """
  Hierarchical locations (board card 7aba0394): each place can name its
  `parent`, and "go in", "go out", "leave" and travel use the tree
  (`TalesForge.Game.Movement`). A session feature, read when a session is
  created. Default on, in every app (founder approval 16 Oct, after the
  playtest pass). HIERARCHICAL_LOCATIONS=off turns it off.
  """
  @spec hierarchical_locations?() :: boolean()
  def hierarchical_locations?,
    do: System.get_env("HIERARCHICAL_LOCATIONS", "on") not in ~w(off false 0)

  def ollama_api_base, do: System.get_env("OLLAMA_API_BASE", "http://localhost:11434")

  defp auto_provider do
    cond do
      present?(xai_api_key()) -> "xai"
      present?(openai_api_key()) -> "openai"
      present?(anthropic_api_key()) -> "anthropic"
      true -> "mock"
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> default
  end

  defp env_float(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_float(value)
    end
  rescue
    ArgumentError -> default
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: String.trim(value) != ""

  # A flag that is off unless its env var says on.
  defp on?(name), do: System.get_env(name, "off") in ~w(on true 1)
end
