defmodule TalesForge.Playtest.RunMeta do
  @moduledoc """
  The conditions a playtest run was played under, stored on its
  `playtest_runs` row when it starts: the release's git commit (`git_sha/0`)
  and the active flags (`flags/2`).

  The commit comes from `GIT_SHA`, baked into the image by the Dockerfile
  (`--build-arg GIT_SHA=...` in the deploy workflows). The Fly image id in
  `build` is not a commit, so before this runs had to be mapped to releases by
  time (tales-forge-docs `docs/analysis-jev-scores-2026-10-07.md`).

  Flags hold no secrets: on/off switches, model names and rubric versions only.
  """

  alias TalesForge.Config
  alias TalesForge.Game.Features
  alias TalesForge.Playtest.JevScorer

  @doc """
  The git commit of the running release, or nil when unknown (local runs,
  images built without the build arg).

      iex> System.put_env("GIT_SHA", "00c370d1a2b3")
      iex> TalesForge.Playtest.RunMeta.git_sha()
      "00c370d1a2b3"
      iex> System.delete_env("GIT_SHA")
      iex> TalesForge.Playtest.RunMeta.git_sha()
      nil
  """
  @spec git_sha() :: String.t() | nil
  def git_sha do
    case System.get_env("GIT_SHA") do
      nil -> nil
      sha -> sha |> String.trim() |> known_sha()
    end
  end

  defp known_sha(sha) when sha in ["", "unknown"], do: nil
  defp known_sha(sha), do: sha

  @doc """
  The flags in force for a run of `persona_id` in a session with `world_state`:

  - `npc_reactions`, `world_agents`: `"on"` / `"off"` (the env switches);
  - `inn_world`, `world_antagonist`: `"on"` / `"off"`, the session's world
    features (`INN_WORLD`, `WORLD_ANTAGONIST`; `TalesForge.Game.Features`).
    Taken from the session, not the env, because they are fixed when the
    session is created and the baseline variant never gets them;
  - `variant`: the session's behaviour variant (`world_state["variant"]`),
    `"default"` when the session has none;
  - `llm_provider`, `gm_model`, `intent_model`: the models that play the game;
  - `jev_rubric`: the persona's Jev rubric version, as stored on its scores.
  """
  @spec flags(String.t(), map() | nil) :: %{String.t() => String.t()}
  def flags(persona_id, world_state \\ %{}) when is_binary(persona_id) do
    %{
      "npc_reactions" => on_off(Config.npc_reactions?()),
      "world_agents" => on_off(Config.world_agents?()),
      "inn_world" => on_off(Features.on?(world_state, "inn_world")),
      "world_antagonist" => on_off(Features.on?(world_state, "antagonist")),
      "variant" => variant(world_state),
      "llm_provider" => Config.llm_provider(),
      "gm_model" => Config.tier2_model() || Config.xai_model(),
      "intent_model" => Config.tier1_model() || Config.xai_model(),
      "jev_rubric" => jev_rubric(persona_id)
    }
  end

  @doc "Short form of a commit for display (first 7 characters), or nil."
  @spec short_sha(String.t() | nil) :: String.t() | nil
  def short_sha(nil), do: nil
  def short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)

  @doc "The GitHub URL of a commit of ex-tales-forge, or nil."
  @spec commit_url(String.t() | nil) :: String.t() | nil
  def commit_url(nil), do: nil
  def commit_url(sha), do: "https://github.com/whyse-ab/ex-tales-forge/commit/" <> sha

  defp variant(%{"variant" => variant}) when is_binary(variant) and variant != "", do: variant
  defp variant(_world_state), do: "default"

  defp jev_rubric(persona_id) do
    JevScorer.rubric_version(persona_id)
  rescue
    KeyError -> nil
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
end
