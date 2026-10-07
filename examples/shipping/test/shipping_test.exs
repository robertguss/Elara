defmodule ShippingTest do
  use ExUnit.Case, async: true

  test "shipping below, at and above the free-shipping threshold" do
    assert Shipping.shipping_fee(0) == 500
    assert Shipping.shipping_fee(4_999) == 500
    assert Shipping.shipping_fee(5_000) == 0
    assert Shipping.shipping_fee(5_001) == 0
  end
end
