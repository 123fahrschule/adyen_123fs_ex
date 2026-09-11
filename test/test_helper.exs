ExUnit.start()

defmodule Adyen123FS.TestAdapter do
  def run(request), do: Process.get(__MODULE__).(request)

  def register(callback), do: Process.put(__MODULE__, callback)

  def client(callback) do
    register(callback)
    Adyen123FS.Client.new(api_key: "key", adapter: __MODULE__)
  end
end
