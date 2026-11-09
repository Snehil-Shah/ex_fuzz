# Used by "mix credo"
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/test/support/fixtures/"]
      },
      strict: true,
      checks: %{
        # Report TODOs without failing on them.
        extra: [{Credo.Check.Design.TagTODO, [exit_status: 0]}]
      }
    }
  ]
}
