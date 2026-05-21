defmodule IdempotencyKit.MixProject do
  use Mix.Project

  def project do
    [
      app: :idempotency_kit,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Composable idempotency primitives for Plug/Phoenix + Ecto flows",
      package: package(),
      source_url: "https://github.com/metacircu1ar/idempotency_kit",
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.13"},
      {:phoenix, "~> 1.7 or ~> 1.8"},
      {:jason, "~> 1.2"},
      {:postgrex, "~> 0.20", only: :test},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/metacircu1ar/idempotency_kit"
      }
    ]
  end
end
