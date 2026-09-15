defmodule Adyen123FS do
  @moduledoc """
  Adyen Checkout for Elixir. Start with `Adyen123FS.Client.new/1`.
  Payment state and persistence belong to the application using this library.
  """

  @doc """
  Generate a random UUID v4 idempotency key. Persist it **before** the request.
  Reuse that same key for retries of that operation, including after a restart.
  Use separate keys for authorisation, capture and each refund.
  """
  @spec idempotency_key() :: String.t()
  def idempotency_key do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
      hex

    Enum.join([a, b, c, d, e], "-")
  end
end
