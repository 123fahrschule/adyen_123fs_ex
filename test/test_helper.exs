ExUnit.start()

defmodule Adyen123FS.TestAdapter do
  def run(request), do: Process.get(__MODULE__).(request)

  def client(callback) do
    Process.put(__MODULE__, callback)
    Adyen123FS.Client.new(api_key: "key", adapter: __MODULE__)
  end
end
