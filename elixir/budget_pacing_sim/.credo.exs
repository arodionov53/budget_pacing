%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        disabled: [
          # Config mirrors the Julia Config struct one field per parameter (48 fields).
          # It is read once per process, so the larger-map representation does not matter.
          {Credo.Check.Warning.StructFieldAmount, []}
        ]
      }
    }
  ]
}
