defmodule Shipping do
  @moduledoc "Shipping fees in integer cents. Free shipping starts at 5,000 cents."

  def shipping_fee(subtotal) when is_integer(subtotal) and subtotal >= 0 do
    if subtotal >= 5_000, do: 0, else: 500
  end
end
