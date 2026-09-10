defmodule Adyen123FS.Error do
  @moduledoc """
  A validation, API, or transport error. Bodies and underlying reasons may contain
  personal data; never log them indiscriminately. `Inspect` omits these fields.
  A transport failure can leave a payment's outcome unknown.
  """
  @derive {Inspect, only: [:kind, :status, :retryable]}
  defstruct [:kind, :status, :body, :reason, :message, headers: %{}, retryable: false]

  @type t :: %__MODULE__{
          kind: :validation | :api | :transport,
          status: integer() | nil,
          body: term(),
          reason: term(),
          message: String.t() | nil,
          headers: map(),
          retryable: boolean()
        }
end
