# Instrumentation time.
# Run: mix run bench/instrument.exs

alias ExFuzz.Instrument

# NOTE: This is pulled in by Rustler and is not explicitly defined as a dev dependency.
modules = Application.spec(:jason, :modules)

Benchee.run(%{
  "#{length(modules)} Jason modules" => fn -> {:ok, _} = Instrument.instrument(modules) end
})
