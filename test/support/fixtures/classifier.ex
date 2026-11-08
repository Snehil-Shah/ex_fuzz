defmodule ExFuzz.Fixtures.Classifier do
  @moduledoc false

  # A branch on one line: line coverage can't tell the two outcomes apart, clause probes can.

  def classify(x), do: if(x > 10, do: :big, else: :small)
end
