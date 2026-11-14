# Used by "mix credo"
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "bench/", "examples/"],
        # Fixtures are test data.
        excluded: [~r"/test/fixtures/"]
      },
      strict: true,
      checks: %{
        # Report TODOs without failing on them.
        extra: [{Credo.Check.Design.TagTODO, [exit_status: 0]}]
      }
    }
  ]
}
