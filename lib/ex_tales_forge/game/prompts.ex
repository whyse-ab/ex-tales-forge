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
  """

  alias TalesForge.Game.Context
  alias TalesForge.Game.Schemas.{HandlerResult, PlayerAction}

  def intent_system, do: read_prompt("intent_system.txt")
  def narrator_system, do: read_prompt("narrator_system.txt")
  def gm_system, do: read_prompt("gm_system.txt")
  def gm_prose_system, do: read_prompt("gm_prose_system.txt")
  def scene_system, do: read_prompt("scene_system.txt")
  def scene_prose_system, do: read_prompt("scene_prose_system.txt")

  @doc "Messages for the opening/arrival scene call."
  def scene_messages(gm_context, opts \\ []) do
    # mode: :prose (GM_REPLY_MODE=prose) swaps only the task message.
    task = if opts[:mode] == :prose, do: scene_prose_system(), else: scene_system()
    narration_messages(gm_context, task, Context.per_turn_section(gm_context))
  end

  @doc "Messages for a GM turn. Per-turn content, including the action, goes last."
  def gm_messages(
        gm_context,
        mechanical,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler,
        turn_number,
        opts \\ []
      ) do
    per_turn =
      Context.per_turn_section(gm_context) <>
        Context.mechanical_bounds(mechanical) <>
        "\n\nValidated player action (turn #{turn_number}):\n" <>
        Jason.encode!(PlayerAction.encode(player_action), pretty: true) <>
        "\n\nAction handler result:\n" <>
        Jason.encode!(handler_payload(handler), pretty: true)

    # mode: :prose (GM_REPLY_MODE=prose prototype) swaps only the task message
    # (3rd); the prefix order and the per-turn content stay the same.
    task = if opts[:mode] == :prose, do: gm_prose_system(), else: gm_system()
    narration_messages(gm_context, task, per_turn)
  end

  defp narration_messages(gm_context, task, per_turn) do
    [
      %{role: "system", content: narrator_system()},
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

  def build_scene_user(%TalesForge.Schemas.GameSession{} = session) do
    TalesForge.Game.Context.format_gm_prompt(TalesForge.Game.Context.build_gm_context(session))
  end

  @doc """
  Load rules for the global system (default, used for legacy / non-pack adventures).
  """
  def load_rules do
    load_rules_from_dir(priv_path("rules"))
  end

  @doc """
  Load rules for a specific adventure, if it has its own pack in priv/adventures/<adventure_id>/rules.

  Falls back to global rules if no pack-specific rules/ directory is found.
  This is the key to making fully self-contained game packs (e.g. "Drakar och Demoner")
  actually drive the GM prompts.
  """
  def load_rules(adventure_id) when is_binary(adventure_id) do
    pack_rules_dir = Path.join([priv_path("adventures"), adventure_id, "rules"])

    if File.dir?(pack_rules_dir) and has_markdown?(pack_rules_dir) do
      load_rules_from_dir(pack_rules_dir)
    else
      load_rules()
    end
  end

  def load_rules(_other), do: load_rules()

  @doc """
  Load rules from an explicit directory (used by the Importer and for pack-aware sessions).
  Walks recursively and concatenates all .md files, sorted by path.
  """
  def load_rules_from_dir(dir) when is_binary(dir) do
    Path.wildcard(Path.join(dir, "**/*.md"))
    |> Enum.sort()
    |> Enum.map_join("\n\n---\n\n", fn path ->
      rel = Path.relative_to(path, dir)
      content = File.read!(path)
      "### #{rel}\n\n#{content}"
    end)
  end

  defp has_markdown?(dir) do
    Path.wildcard(Path.join(dir, "**/*.md")) != []
  end

  defp read_prompt(name) do
    path = priv_path("prompts/#{name}")
    File.read!(path)
  end

  # Resolved at runtime: in a release priv lives under /app/lib/ex_tales_forge-<vsn>/priv,
  # not under the _build path a compile-time module attribute would capture.
  defp priv_path(rel), do: Path.join(:code.priv_dir(:ex_tales_forge), rel)
end
