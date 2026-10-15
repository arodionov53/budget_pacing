defmodule BudgetPacingSim.Grant do
  @moduledoc """
  A grant: the client may spend at most `amount` (client-counted) at pace `rate`
  while `issue_tick <= tick < expiry_tick`.
  """

  defstruct [
    :client,       # client id
    :amount,       # max client-counted spend
    :rate,         # spend rate [money/min]
    :lam_issue,    # client demand estimate at issue time
    :issue_tick,   # tick when issued
    :expiry_tick,  # tick when it expires
    switch_tick: nil,   # tick when client stopped using it (nil = still in use)
    release_tick: nil   # tick from which center may free unused part (nil = not yet)
  ]

  @type t :: %__MODULE__{
          client: pos_integer(),
          amount: float(),
          rate: float(),
          lam_issue: float(),
          issue_tick: pos_integer(),
          expiry_tick: pos_integer(),
          switch_tick: pos_integer() | nil,
          release_tick: pos_integer() | nil
        }
end
