defmodule ExFuzz.Corpus do
  @moduledoc false

  # Input corpus.

  alias ExFuzz.Config

  @doc "The test's corpus."
  @spec load(module(), atom()) :: [{Path.t(), binary()}]
  def load(module, test), do: read(dir(Config.get(:corpus_dir), module, test))

  @doc "Saves `input` to the test's corpus. Returns its path."
  @spec save(module(), atom(), binary()) :: Path.t()
  def save(module, test, input), do: write(dir(Config.get(:corpus_dir), module, test), input)

  @doc "The test's cache."
  @spec load_cache(module(), atom()) :: [{Path.t(), binary()}]
  def load_cache(module, test), do: read(dir(Config.get(:cache_dir), module, test))

  @doc "Saves `input` to the test's cache. Returns its path."
  @spec save_cache(module(), atom(), binary()) :: Path.t()
  def save_cache(module, test, input), do: write(dir(Config.get(:cache_dir), module, test), input)

  # Normalized corpus directory: `<base>/MyApp.JSONTest/Jason_never_crashes`.
  defp dir(base, module, test), do: Path.join([base, inspect(module), name(test)])

  # `:"fuzz Jason never crashes"` - `Jason_never_crashes`.
  defp name(test) do
    test
    |> Atom.to_string()
    |> String.replace_prefix("fuzz ", "")
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp read(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        for file <- Enum.sort(files), path = Path.join(dir, file), do: {path, File.read!(path)}

      {:error, :enoent} ->
        []
    end
  end

  defp write(dir, input) do
    hash = :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(dir, hash)
    File.mkdir_p!(dir)
    File.write!(path, input)
    path
  end
end
