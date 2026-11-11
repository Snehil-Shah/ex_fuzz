defmodule ExFuzz.Scope do
  @moduledoc false

  # This module answers: "What to instrument?"

  @doc """
  The project's modules and `called` (the target's calls), and every
  recursive module call, within the project and its dependencies.
  """
  @spec modules([module()]) :: [module()]
  def modules(called) do
    project = Mix.Project.config()[:app]
    apps = MapSet.delete(MapSet.new([project | Mix.Project.deps_apps()]), :ex_fuzz)
    project_modules = Application.spec(project, :modules) || []
    start = for module <- project_modules ++ called, app(module) in apps, uniq: true, do: module
    follow(start, MapSet.new(start), apps) |> MapSet.to_list()
  end

  # `modules`, and every module they call, recursively, that belongs to one of `apps`.
  defp follow([], seen, _apps), do: seen

  defp follow(modules, seen, apps) do
    next =
      for module <- modules,
          called <- calls(module),
          not MapSet.member?(seen, called),
          app(called) in apps,
          uniq: true,
          do: called

    follow(next, MapSet.union(seen, MapSet.new(next)), apps)
  end

  # Direct calls and captures (`&Mod.fun/1`).
  defp calls(module) do
    case :code.get_object_code(module) do
      {^module, beam, _file} -> Enum.uniq(imports(module, beam) ++ captures(module, beam))
      :error -> []
    end
  end

  defp imports(module, beam) do
    case :beam_lib.chunks(beam, [:imports]) do
      {:ok, {^module, [imports: imports]}} -> Enum.map(imports, &elem(&1, 0))
      _ -> []
    end
  end

  defp captures(module, beam) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} when data != :none <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      for {:function, _, _, _, clauses} <- forms, do: remote_funs(clauses, [])
    else
      _ -> []
    end
    |> List.flatten()
  end

  # `fun Mod:fun/Arity` with a literal module.
  defp remote_funs({:fun, _, {:function, {:atom, _, module}, _name, _arity}}, acc),
    do: [module | acc]

  defp remote_funs(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> remote_funs(acc)

  defp remote_funs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &remote_funs/2)
  defp remote_funs(_other, acc), do: acc

  defp app(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end
end
