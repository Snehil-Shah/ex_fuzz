defmodule ExFuzz.Scope do
  @moduledoc false

  # This module answers: "What to instrument?"

  @doc """
  The project's instrumentation scope.

  Includes every recursive module call within the project (+ `additional`) and its dependencies.
  """
  @spec modules([module()]) :: [module()]
  def modules(additional) do
    project = Mix.Project.config()[:app]
    apps = MapSet.delete(MapSet.new([project | Mix.Project.deps_apps()]), :ex_fuzz)
    project_modules = Application.spec(project, :modules) || []

    start =
      for module <- project_modules ++ additional, app(module) in apps, uniq: true, do: module

    follow(start, MapSet.new(start), apps) |> MapSet.to_list()
  end

  @doc "The modules called by `block`."
  @spec modules_called_by(Macro.t(), Macro.Env.t()) :: [module()]
  def modules_called_by(block, env) do
    {_block, modules} =
      Macro.prewalk(block, MapSet.new(), fn
        {{:., _, [module, function]}, _, args} = node, acc
        when is_atom(function) and is_list(args) ->
          {node, remote(module, env, acc)}

        # A capture: its `/` isn't a call, so the walk doesn't go inside (`nil`).
        {:&, _, [{:/, _, [callee, arity]}]}, acc when is_integer(arity) ->
          {nil, captured(callee, arity, env, acc)}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, imported(env, name, length(args), acc)}

        node, acc ->
          {node, acc}
      end)

    modules |> MapSet.to_list() |> Enum.sort()
  end

  defp captured({{:., _, [module, _function]}, _, []}, _arity, env, acc),
    do: remote(module, env, acc)

  defp captured({name, _, context}, arity, env, acc) when is_atom(name) and is_atom(context),
    do: imported(env, name, arity, acc)

  defp captured(_callee, _arity, _env, acc), do: acc

  # `Alias.fun`, expanded as the compiler would.
  defp remote(module, env, acc) do
    case Macro.expand(module, env) do
      module when is_atom(module) -> MapSet.put(acc, module)
      _variable -> acc
    end
  end

  defp imported(env, name, arity, acc) do
    for {:function, module} <- Macro.Env.lookup_import(env, {name, arity}), into: acc, do: module
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
