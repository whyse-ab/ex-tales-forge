defmodule TalesForge.Game.Prompts do
  @moduledoc """
  Prompt files and message assembly for the narration calls (scene and GM turn).

  Message order is fixed so xAI's prompt cache can reuse the longest prefix:

  1. system: `narrator_system.txt` — shared table voice, identical for every call
  2. system: the adventure's rules — identical for the scene call and every GM turn
  3. system: the task (`scene_system.txt` or `gm_system.txt`)
  4. user: session-stable content (character sheet, adventure, opening scene)
  5. user: per-turn state (facts, location, inventory, NPCs, recent turns, and
     for a GM turn the server resolution, the validated PlayerAction and handler)

  1–2 are byte-identical between the scene call and the GM calls, so with the
  same `x-grok-conv-id` the opening scene warms the cache for GM turn 1. Nothing
  in 1–4 may change per turn; `test/ex_tales_forge/game/prompt_prefix_test.exs`
  guards this.

  A session's behaviour variant (`TalesForge.Game.Variant`) picks the prompt
  files: `priv/prompts/variants/<variant>/<file>` replaces `priv/prompts/<file>`
  when it exists. The variant is fixed per session, so the cached prefix is too.
  """

  alias TalesForge.Game.Context
  alias TalesForge.Game.Schemas.{HandlerResult, MechanicalResolution, PlayerAction}
  alias TalesForge.Game.Variant

  @doc "System prompt of the intent step (`priv/prompts/intent_system.txt`) for a variant."
  @spec intent_system(Variant.t()) :: String.t()
  def intent_system(variant \\ "default"), do: read_prompt("intent_system.txt", variant)

  @doc "Shared table voice, message 1 of every narration call (`narrator_system.txt`)."
  @spec narrator_system(Variant.t()) :: String.t()
  def narrator_system(variant \\ "default"), do: read_prompt("narrator_system.txt", variant)

  @doc "Task prompt of a GM turn, message 3 (`gm_system.txt`)."
  @spec gm_system(Variant.t()) :: String.t()
  def gm_system(variant \\ "default"), do: read_prompt("gm_system.txt", variant)

  @doc "Task prompt of the opening/arrival scene, message 3 (`scene_system.txt`)."
  @spec scene_system(Variant.t()) :: String.t()
  def scene_system(variant \\ "default"), do: read_prompt("scene_system.txt", variant)

  @doc "Messages for the opening/arrival scene call."
  @spec scene_messages(map()) :: [%{role: String.t(), content: String.t()}]
  def scene_messages(gm_context) do
    narration_messages(
      gm_context,
      scene_system(variant(gm_context)),
      Context.per_turn_section(gm_context)
    )
  end

  @doc "Messages for a GM turn. Per-turn content, including the action, goes last."
  @spec gm_messages(
          map(),
          MechanicalResolution.t() | nil,
          PlayerAction.t(),
          HandlerResult.t(),
          integer()
        ) ::
          [%{role: String.t(), content: String.t()}]
  def gm_messages(
        gm_context,
        mechanical,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler,
        turn_number
      ) do
    per_turn =
      Context.per_turn_section(gm_context) <>
        Context.mechanical_bounds(mechanical) <>
        "\n\nValidated player action (turn #{turn_number}):\n" <>
        Jason.encode!(PlayerAction.encode(player_action), pretty: true) <>
        "\n\nAction handler result:\n" <>
        Jason.encode!(handler_payload(handler), pretty: true)

    narration_messages(gm_context, gm_system(variant(gm_context)), per_turn)
  end

  defp variant(gm_context), do: Variant.of(Map.get(gm_context, :world_state))

  defp narration_messages(gm_context, task, per_turn) do
    [
      %{role: "system", content: narrator_system(variant(gm_context))},
      %{role: "system", content: gm_context.rules},
      %{role: "system", content: task},
      %{role: "user", content: Context.session_stable_section(gm_context)},
      %{role: "user", content: per_turn}
    ]
  end

  defp handler_payload(%HandlerResult{} = handler) do
    %{
      "handler" => handler.handler,
      "skill" => handler.skill,
      "target" => handler.target,
      "notes" => handler.notes
    }
  end

  @doc "The whole scene context of a session as one flat string (for tests and debugging)."
  @spec build_scene_user(TalesForge.Schemas.GameSession.t()) :: String.t()
  def build_scene_user(%TalesForge.Schemas.GameSession{} = session) do
    TalesForge.Game.Context.format_gm_prompt(TalesForge.Game.Context.build_gm_context(session))
  end

  @doc """
  Load the global rules in `priv/rules` (used by adventures without their own rules folder).
  """
  @spec load_rules() :: String.t()
  def load_rules do
    load_rules_from_dir(priv_path("rules"))
  end

  @doc """
  Load rules for a specific adventure, if it has its own pack in priv/adventures/<adventure_id>/rules.

  Falls back to global rules if no pack-specific rules/ directory is found.
  This is the key to making fully self-contained game packs (e.g. "Drakar och Demoner")
  actually drive the GM prompts.

  A behaviour variant (`TalesForge.Game.Variant`) can replace whole rule files:
  `<root>/variants/<variant>/rules/<file>.md` takes the place of
  `<root>/rules/<file>.md`, where the root is the pack folder (or `priv/` for
  the global rules). The baseline arm uses this to keep the rules text it was
  written against.
  """
  @spec load_rules(String.t() | nil, Variant.t()) :: String.t()
  def load_rules(adventure_id, variant \\ "default")

  def load_rules(adventure_id, variant) when is_binary(adventure_id) do
    pack_rules_dir = Path.join([priv_path("adventures"), adventure_id, "rules"])

    if File.dir?(pack_rules_dir) and has_markdown?(pack_rules_dir) do
      load_rules_from_dir(pack_rules_dir, variant)
    else
      load_rules_from_dir(priv_path("rules"), variant)
    end
  end

  def load_rules(_other, variant), do: load_rules_from_dir(priv_path("rules"), variant)

  @doc """
  Load rules from an explicit directory (used by the Importer and for pack-aware sessions).
  Walks recursively and concatenates all .md files, sorted by path. For a
  variant other than `"default"`, a file under
  `<dir>/../variants/<variant>/rules/` with the same relative path replaces the
  file's content (the heading keeps the relative path).
  """
  @spec load_rules_from_dir(String.t(), Variant.t()) :: String.t()
  def load_rules_from_dir(dir, variant \\ "default") when is_binary(dir) do
    override_dir =
      Path.join([Path.dirname(dir), "variants", Variant.of(%{"variant" => variant}), "rules"])

    Path.wildcard(Path.join(dir, "**/*.md"))
    |> Enum.sort()
    |> Enum.map_join("\n\n---\n\n", fn path ->
      rel = Path.relative_to(path, dir)
      override = Path.join(override_dir, rel)
      content = if File.regular?(override), do: File.read!(override), else: File.read!(path)
      "### #{rel}\n\n#{content}"
    end)
  end

  defp has_markdown?(dir) do
    Path.wildcard(Path.join(dir, "**/*.md")) != []
  end

  defp read_prompt(name, variant) do
    override = priv_path("prompts/variants/#{Variant.of(%{"variant" => variant})}/#{name}")

    if File.exists?(override),
      do: File.read!(override),
      else: File.read!(priv_path("prompts/#{name}"))
  end

  # Resolved at runtime: in a release priv lives under /app/lib/ex_tales_forge-<vsn>/priv,
  # not under the _build path a compile-time module attribute would capture.
  defp priv_path(rel), do: Path.join(:code.priv_dir(:ex_tales_forge), rel)
end
