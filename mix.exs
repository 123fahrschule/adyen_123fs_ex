defmodule Adyen123FS.MixProject do
  use Mix.Project

  def project do
    [
      app: :adyen_123fs_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Adyen123FS",
      description: "A Req-based Adyen Checkout client for Elixir",
      source_url: "https://github.com/123fahrschule/adyen_123fs_ex",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end
end
