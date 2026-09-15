defmodule WithoutPlug.MixProject do
  use Mix.Project

  def project do
    [
      app: :without_plug,
      version: "0.0.0",
      lockfile: Path.expand("../../mix.lock", __DIR__),
      deps: [{:adyen_123fs_ex, path: Path.expand("../..", __DIR__)}]
    ]
  end
end
