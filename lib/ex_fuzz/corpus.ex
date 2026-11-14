defmodule ExFuzz.Corpus do
  @moduledoc false

  # Input corpus.

  alias ExFuzz.Config

  @version "ex_fuzz v1"

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
        for file <- Enum.sort(files), path = Path.join(dir, file), do: {path, decode!(path)}

      {:error, :enoent} ->
        []
    end
  end

  defp write(dir, input) do
    contents = encode(input)
    hash = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    path = Path.join(dir, hash)
    File.mkdir_p!(dir)
    File.write!(path, contents)
    path
  end

  # Encode input as a string literal.
  # NOTE: `inspect` loses bytes on older Elixir versions, so we hand roll our own deterministic encoder.
  # Ref: https://github.com/elixir-lang/elixir/commit/44085d43476e3db956b03dfe36de65a7da1926a9
  defp encode(input) do
    @version <> "\n\"" <> for(<<byte <- input>>, into: "", do: escape(byte)) <> "\"\n"
  end

  defp escape(?"), do: ~S(\")
  defp escape(?\\), do: ~S(\\)
  defp escape(?#), do: ~S(\#)
  defp escape(?\n), do: ~S(\n)
  defp escape(?\r), do: ~S(\r)
  defp escape(?\t), do: ~S(\t)
  defp escape(byte) when byte in 0x20..0x7E, do: <<byte>>
  defp escape(byte), do: "\\x" <> Base.encode16(<<byte>>)

  # Line endings may be `\r\n` after a git checkout.
  defp decode!(path) do
    with [version, literal] <- String.split(File.read!(path), "\n", parts: 2),
         @version <- String.trim_trailing(version, "\r"),
         {:ok, input} when is_binary(input) <-
           Code.string_to_quoted(literal, existing_atoms_only: true) do
      input
    else
      _ -> raise "invalid corpus file: #{path}"
    end
  end
end
