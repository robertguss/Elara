defmodule Elara.Benchmark.Adapter do
  @moduledoc false

  @callback execute(task :: map(), cwd :: String.t(), context :: map()) ::
              {:ok, map()} | {:error, term()}
end
