defmodule HarnessTest do
  use ExUnit.Case
  doctest Harness

  test "greets the world" do
    assert Harness.hello() == :world
  end
end
