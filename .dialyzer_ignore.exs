# Dialyzer warnings we accept for now (see tales-forge-docs docs/coding-standards.md).
#
# Legacy baseline: list a warning here only with a reason and an owner, e.g.
#   {"lib/ex_tales_forge/some_module.ex", :guard_fail}
# New code must not add entries; fix the warning instead.
# Empty on 2026-10-07: the first full Dialyzer run found 22 warnings and all
# were fixed (one was a real bug in Collab.Importer's date parsing).
[]
