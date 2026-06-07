defmodule Negotiator.SileroVad do
  @moduledoc """
  probabilistic end-of-turn boundary.
  """

  defmodule Decision do
    @moduledoc """
    turn timing decision for streaming speech.
    """

    defstruct end_probability: 0.0,
              should_wait?: true,
              should_reply?: false,
              reason: nil
  end

  @callback score(map()) :: Decision.t()
end
