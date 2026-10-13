defmodule ElaraLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :elara_lab,
      version: "0.1.0",
      elixir: "~> 1.20",
      # The product's lock, so the lab runs the product's exact dependencies.
      lockfile: "../mix.lock",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # :elara builds as it does when run from source (`mix elara.*` in dev), so the
  # lab drives the same debug exec-stub in every lab environment.
  defp deps do
    [{:elara, path: "..", env: :dev}]
  end
end
