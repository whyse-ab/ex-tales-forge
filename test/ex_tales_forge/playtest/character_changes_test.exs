defmodule TalesForge.Playtest.CharacterChangesTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.GameSessions
  alias TalesForge.NPC
  alias TalesForge.Playtest.CharacterChanges
  alias TalesForge.Playtest.CharacterChanges.{Character, Field, RunMetrics, Summary}
  alias TalesForge.Schemas.{AICall, GameSession, PlaytestRun, SessionEvent, Turn}

  doctest CharacterChanges

  @t1 ~U[2026-10-08 07:08:38Z]
  @t2 ~U[2026-10-08 07:09:18Z]

  defp sources(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        world: %{
          "npc_moods" => %{
            "innkeep" => %{
              "emotion" => "calm",
              "intensity" => 0.38,
              "stance" => "friendly",
              "confidence" => 0.42,
              "turn_number" => 2
            }
          },
          "character" => %{
            "id" => "pc_corvin",
            "name" => "Corvin",
            "coins" => %{"silver" => 47},
            "wounds" => 1,
            "wound_max" => 3,
            "vitality" => "hurt",
            "learning_points" => %{"survival" => 0.5},
            "skills" => %{"survival" => 4, "insight" => 3}
          },
          "location_id" => "inn_yard"
        },
        npcs: [
          %{
            npc_id: "innkeep",
            name: "Brenna",
            default_location_id: "valley_inn",
            start_mood: "cheerful",
            start_concern: %{"focus" => "guests", "priority" => 6},
            runtime: %{
              "location_id" => "valley_inn",
              "mood" => "cheerful",
              "relationship_score" => 0.15,
              "current_concern" => %{"focus" => "guests", "priority" => 8},
              "memories" => [
                %{
                  "summary" => "Corvin bought ale.",
                  "tick" => 37,
                  "at" => "2026-10-08T07:08:38.1Z"
                },
                %{"summary" => "Player spoke to me: Evening!", "tick" => 37},
                %{"summary" => "Overheard player: Hello there", "tick" => 38}
              ]
            }
          },
          %{
            npc_id: "smith",
            name: "Hild",
            default_location_id: "smithy",
            start_mood: "uneasy",
            start_concern: nil,
            runtime: %{"location_id" => "smithy", "mood" => "uneasy", "relationship_score" => 0.0}
          }
        ],
        characters: [
          %{
            slug: "pc_corvin",
            controller: "bot",
            name: "Corvin",
            maslow_level: "self_actualisation",
            concerns: [%{text: "Keep the faithful on the right path", priority: 5}],
            ocean: %{
              openness: 5,
              conscientiousness: 8,
              extraversion: 6,
              agreeableness: 7,
              neuroticism: 6
            },
            definition: %{
              "id" => "pc_corvin",
              "coins" => %{"silver" => 20, "copper" => 300},
              "wounds" => 0,
              "wound_max" => 3,
              "vitality" => "ok",
              "learning_points" => %{},
              "skills" => %{"survival" => 3, "insight" => 3},
              "maslow" => "self_actualisation"
            }
          },
          %{
            slug: "innkeep",
            controller: "gm",
            name: "Brenna",
            maslow_level: "belonging",
            concerns: [%{text: "Keep the room warm", priority: 6}],
            ocean: %{
              openness: 6,
              conscientiousness: 7,
              extraversion: 8,
              agreeableness: 8,
              neuroticism: 3
            },
            definition: nil
          }
        ],
        memories: [
          # Mirrored only (fell out of the runtime list): placed by timestamp.
          %{
            slug: "innkeep",
            tick: nil,
            text: "broke the Tinjacks",
            felt: "grateful",
            inserted_at: @t2
          },
          # Mirrored and still in the runtime list: not counted twice.
          %{slug: "innkeep", tick: 37, text: "Corvin bought ale.", felt: nil, inserted_at: @t1}
        ],
        gm_turns: [
          %{
            tick: 37,
            turn_number: 1,
            updates: [%{"npc_id" => "innkeep", "summary" => "Corvin bought ale."}]
          },
          %{tick: 38, turn_number: 2, updates: []}
        ],
        travel: [%{tick: 38, from: "valley_inn", to: "inn_yard"}],
        turns: [
          %{
            id: "t1",
            turn_number: 1,
            inserted_at: @t1,
            lp_awarded: nil,
            lp_skill: nil,
            improvements: []
          },
          %{
            id: "t2",
            turn_number: 2,
            inserted_at: @t2,
            lp_awarded: 0.5,
            lp_skill: "survival",
            improvements: [%{"skill" => "survival", "improved" => true}]
          }
        ],
        reaction_calls: [
          %{turn_number: 1, status: "ok", count: 1},
          %{turn_number: 2, status: "ok", count: 1},
          %{turn_number: 2, status: "error", count: 1}
        ]
      },
      overrides
    )
  end

  defp character(changes, slug), do: Enum.find(changes.characters, &(&1.slug == slug))
  defp field(%Character{fields: fields}, key), do: Enum.find(fields, &(&1.key == key))

  describe "build/1" do
    test "NPC: start versus end, memories with their turn and writer" do
      changes = CharacterChanges.build(sources())
      brenna = character(changes, "innkeep")

      assert brenna.changed?

      assert %Field{status: :changed, start_value: "0.00", end_value: "0.15"} =
               field(brenna, :relationship)

      assert %Field{status: :changed, end_value: "friendly (turn 2)"} = field(brenna, :stance)
      assert field(brenna, :feeling).end_value =~ "calm (0.38)"
      assert %Field{status: :unchanged, end_value: "cheerful"} = field(brenna, :mood)

      assert %Field{status: :changed, start_value: "guests (priority 6)"} =
               field(brenna, :concern)

      assert %Field{start_value: "0", end_value: "4"} = field(brenna, :memories)

      assert Enum.map(brenna.memories_added, &{&1.turn_number, &1.source}) == [
               {1, :gm},
               {1, :heard},
               {2, :world},
               {2, :overheard}
             ]

      assert %{felt: "grateful"} = Enum.find(brenna.memories_added, &(&1.source == :world))

      labels = Enum.map(brenna.not_tracked, & &1.label)
      assert "Feelings toward other NPCs" in labels

      assert %Field{start_value: "belonging", status: :not_tracked} =
               Enum.find(brenna.not_tracked, &(&1.key == :maslow))

      assert %Field{start_value: "O6 C7 E8 A8 N3"} =
               Enum.find(brenna.not_tracked, &(&1.key == :ocean_memory))
    end

    test "an NPC without a reaction or a change is listed after the changed ones" do
      changes = CharacterChanges.build(sources())
      assert Enum.map(changes.characters, & &1.slug) == ["pc_corvin", "innkeep", "smith"]

      hild = character(changes, "smith")
      refute hild.changed?
      assert %Field{status: :unchanged, end_value: "neutral"} = field(hild, :stance)
      assert field(hild, :feeling) == nil
      assert field(hild, :concern) == nil
      # No characters row for her: the levers say so instead of guessing.
      assert [%Field{key: :toward_npcs}, %Field{key: :levers}] = hild.not_tracked
    end

    test "player character: sheet start versus end, and what is not tracked" do
      pc = CharacterChanges.build(sources()) |> character("pc_corvin")

      assert pc.kind == :pc
      assert pc.controller == "bot"
      assert %Field{start_value: "valley_inn", end_value: "inn_yard"} = field(pc, :location)

      assert %Field{start_value: "0/3 wounds, ok", end_value: "1/3 wounds, hurt"} =
               field(pc, :condition)

      assert %Field{start_value: "20 silver, 300 copper", end_value: "47 silver"} =
               field(pc, :coins)

      assert %Field{end_value: "survival 0.50"} = field(pc, :learning_points)
      assert %Field{start_value: "survival 3", end_value: "survival 4"} = field(pc, :skills)

      assert Enum.map(pc.not_tracked, & &1.key) ==
               [:memories, :toward_npcs, :mood, :maslow, :concerns, :ocean_memory]

      assert pc.memories_added == []
    end

    test "timeline: per turn, with travel, learning and reactions" do
      changes = CharacterChanges.build(sources())

      assert [%{turn_number: 1, turn_id: "t1"} = t1, %{turn_number: 2, turn_id: "t2"} = t2] =
               changes.timeline

      assert Enum.any?(t1.changes, &(&1.kind == :memory and &1.text =~ "GM: Corvin bought ale."))
      assert Enum.any?(t1.changes, &(&1.text =~ "Jev read 1 reaction(s);"))
      assert Enum.any?(t2.changes, &(&1.kind == :travel and &1.text == "valley_inn → inn_yard"))

      assert Enum.any?(
               t2.changes,
               &(&1.kind == :learning and &1.text == "+0.50 LP (survival), survival improved")
             )

      assert Enum.any?(t2.changes, &(&1.text =~ "1 failed"))
      assert Enum.any?(t2.changes, &(&1.text =~ "latest kept reaction: calm"))
    end

    test "without NPC reactions the stance is not tracked, and the notes say so" do
      changes =
        CharacterChanges.build(
          sources(%{world: %{"location_id" => "inn_yard"}, reaction_calls: [], characters: []})
        )

      refute changes.reactions_tracked?
      brenna = character(changes, "innkeep")
      assert %Field{status: :not_tracked} = field(brenna, :stance)
      assert field(brenna, :feeling) == nil
      refute Enum.any?(changes.notes, &(&1 =~ "Jev NPC reactions"))
      assert Enum.any?(changes.notes, &(&1 =~ "No characters rows"))
      # No PC row and no sheet: no player character block.
      assert Enum.all?(changes.characters, &(&1.kind == :npc))
    end

    test "turns without a gm_reasoning event place memories by timestamp" do
      changes = CharacterChanges.build(sources(%{gm_turns: []}))
      brenna = character(changes, "innkeep")

      assert Enum.find(brenna.memories_added, &(&1.text == "Corvin bought ale.")).turn_number == 1
      # Memories with neither a turn tick nor a timestamp: turn unknown.
      assert Enum.find(brenna.memories_added, &(&1.text =~ "Overheard")).turn_number == nil
      assert Enum.any?(changes.notes, &(&1 =~ "2 turn(s) have no gm_reasoning event"))
      assert List.last(changes.timeline).turn_number == nil
    end
  end

  describe "run_metrics/1 and summarize/1" do
    test "per-run numbers" do
      metrics = sources() |> CharacterChanges.build() |> CharacterChanges.run_metrics()

      assert metrics == %RunMetrics{
               memories_added: 4,
               npcs_changed: 1,
               npcs_attitude_changed: 1,
               stance_changed?: true,
               relationship_changed?: true,
               attitude_changed?: true,
               reactions_tracked?: true
             }
    end

    test "batch summary: share, median and mean" do
      runs = [
        %RunMetrics{
          memories_added: 1,
          npcs_changed: 1,
          relationship_changed?: true,
          attitude_changed?: true
        },
        %RunMetrics{memories_added: 3, npcs_changed: 2, reactions_tracked?: true},
        %RunMetrics{memories_added: 8, npcs_changed: 0}
      ]

      assert %Summary{
               runs: 3,
               attitude_changed: 1,
               relationship_changed: 1,
               stance_changed: 0,
               reaction_runs: 1,
               memories_median: 3.0,
               memories_mean: 4.0,
               npcs_changed_median: 1.0,
               npcs_changed_mean: 1.0,
               attitude_npcs_median: +0.0
             } = summary = CharacterChanges.summarize(runs)

      assert_in_delta summary.attitude_changed_share, 1 / 3, 1.0e-9

      assert %Summary{runs: 0, attitude_changed_share: nil, memories_median: nil} =
               CharacterChanges.summarize([])
    end
  end

  describe "for_session/1 and batches/1 (database)" do
    setup do
      {:ok, session} = GameSessions.create_session(%{name: "cc", adventure_id: "tin_valley"})
      %{session: session}
    end

    test "reads the scattered state of a played session", %{session: session} do
      seed_played_turn(session)

      changes = CharacterChanges.for_session(session.id)
      brenna = character(changes, "innkeep")

      assert changes.reactions_tracked?
      assert [%{source: :gm, turn_number: 1, text: "Corvin bought ale."}] = brenna.memories_added
      assert %Field{status: :changed, end_value: "0.10"} = field(brenna, :relationship)
      assert %Field{status: :changed, end_value: "warm (turn 1)"} = field(brenna, :stance)
      assert Enum.any?(brenna.not_tracked, &(&1.key == :maslow and is_binary(&1.start_value)))

      pc = Enum.find(changes.characters, &(&1.kind == :pc))
      assert pc
      assert field(pc, :condition)
      assert [%{turn_number: 1, changes: changes_t1}] = changes.timeline
      assert Enum.any?(changes_t1, &(&1.slug == "innkeep" and &1.kind == :memory))

      assert %RunMetrics{memories_added: 1, attitude_changed?: true} =
               CharacterChanges.run_metrics(changes)
    end

    test "an unknown session gives an empty result" do
      id = Ecto.UUID.generate()

      assert %CharacterChanges{session_id: ^id, characters: [], timeline: []} =
               CharacterChanges.for_session(id)

      assert CharacterChanges.for_sessions([]) == %{}
    end

    test "batches group runs by series tag; series_summary per variant", %{session: session} do
      seed_played_turn(session)
      {:ok, other} = GameSessions.create_session(%{name: "cc2", adventure_id: "tin_valley"})

      a = insert_run(session.id, "series=ab-1 variant=default", 1, "finished")
      b = insert_run(other.id, "series=ab-1 variant=baseline", 1, "stopped")
      running = insert_run(other.id, "series=ab-1 variant=baseline", 1, "running")
      empty = insert_run(other.id, nil, 0, "failed")

      batches = CharacterChanges.batches([a, b, running, empty])
      assert Enum.map(batches, & &1.label) |> Enum.sort() == ["ab-1 · baseline", "ab-1 · default"]

      default = Enum.find(batches, &(&1.label == "ab-1 · default"))
      assert %Summary{runs: 1, attitude_changed: 1, memories_mean: 1.0} = default.summary

      by_variant = CharacterChanges.series_summary("ab-1")
      assert %Summary{runs: 1, attitude_changed: 0} = by_variant["baseline"]
      assert %Summary{runs: 1, attitude_changed: 1} = by_variant["default"]
      assert CharacterChanges.series_summary("nope") == %{}
    end
  end

  defp seed_played_turn(session) do
    session = Repo.get!(GameSession, session.id)
    tick = session.world_state["world_tick"] + 1

    Repo.insert!(%Turn{
      game_session_id: session.id,
      turn_number: 1,
      player_action: "Evening!",
      narrative: "Brenna smiles.",
      mechanical_resolution: %{"outcome" => "none", "improvements" => []}
    })

    Repo.insert!(%SessionEvent{
      game_session_id: session.id,
      kind: "gm_reasoning",
      actor: "gm",
      player_aware: false,
      tick: tick,
      payload: %{
        "turn_number" => 1,
        "gm_reply" => %{
          "npc_memory_updates" => [%{"npc_id" => "innkeep", "summary" => "Corvin bought ale."}]
        }
      }
    })

    :ok = NPC.record_memory(session.id, "innkeep", "Corvin bought ale.", tick)
    {:ok, _} = NPC.bump_relationship(session.id, "innkeep", 0.1)

    world =
      Map.put(session.world_state, "npc_moods", %{
        "innkeep" => %{"emotion" => "curious", "stance" => "warm", "turn_number" => 1}
      })

    session |> GameSession.changeset(%{world_state: world}) |> Repo.update!()

    Repo.insert!(%AICall{
      game_session_id: session.id,
      purpose: "npc_reaction",
      call_type: "jev",
      model: "jev",
      status: "ok",
      turn_number: 1,
      latency_ms: 10
    })
  end

  defp insert_run(session_id, notes, turns, status) do
    Repo.insert!(%PlaytestRun{
      game_session_id: session_id,
      persona: "paul",
      module: "tin_valley",
      turn_limit: 5,
      turns_played: turns,
      status: status,
      notes: notes,
      started_at: DateTime.utc_now(:second)
    })
  end
end
