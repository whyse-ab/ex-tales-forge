%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5_000,
      color: true,
      checks: %{
        enabled: [
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CaseTrivialMatches, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnsafeExec, []},
          # Coding standards (tales-forge-docs docs/coding-standards.md): every
          # module has a @moduledoc (`@moduledoc false` only for internals).
          {Credo.Check.Readability.ModuleDoc, []},
          # @spec on every public function, enforced for the modules backfilled
          # so far. Add a file here once its public functions all have specs;
          # the rest of lib/ is the legacy baseline, still to be backfilled.
          {Credo.Check.Readability.Specs,
           [
             files: %{
               included: [
                 "lib/ex_tales_forge/llm.ex",
                 "lib/ex_tales_forge/collab/links.ex",
                 "lib/ex_tales_forge/collab/files.ex",
                 "lib/ex_tales_forge_web/controllers/doc_files_controller.ex",
                 "lib/mix/tasks/docs.check_links.ex",
                 "lib/ex_tales_forge/game/turn_processor.ex",
                 "lib/ex_tales_forge/game/context.ex",
                 "lib/ex_tales_forge/game/intent.ex",
                 "lib/ex_tales_forge/game/movement.ex",
                 "lib/ex_tales_forge/game/prompts.ex",
                 "lib/ex_tales_forge/game/npc_reactions.ex",
                 "lib/ex_tales_forge/game/mechanics.ex",
                 "lib/ex_tales_forge/game/progression.ex",
                 "lib/ex_tales_forge/game/progression/",
                 "lib/ex_tales_forge/game/train.ex",
                 "lib/ex_tales_forge/world.ex",
                 "lib/ex_tales_forge/world/",
                 "lib/ex_tales_forge/game/features.ex",
                 "lib/ex_tales_forge_web/time_ago.ex",
                 "lib/ex_tales_forge/surveys.ex",
                 "lib/ex_tales_forge/survey/",
                 "lib/ex_tales_forge_web/components/survey_components.ex",
                 "lib/ex_tales_forge_web/controllers/survey_export_controller.ex",
                 "lib/ex_tales_forge/playtest/character_changes.ex",
                 "lib/ex_tales_forge/playtest/character_changes/",
                 "lib/ex_tales_forge_web/components/character_changes_components.ex",
                 "lib/ex_tales_forge/app_role.ex",
                 "lib/ex_tales_forge_web/plugs/home_app.ex",
                 "lib/ex_tales_forge/costs.ex",
                 "lib/ex_tales_forge/costs/",
                 "lib/ex_tales_forge_web/controllers/costs_peer_controller.ex",
                 "lib/ex_tales_forge_web/live/admin/costs_live.ex"
               ]
             }
           ]}
        ],
        disabled: [
          # Nested module refs are common in Phoenix/Jido code; alias at top is optional
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
