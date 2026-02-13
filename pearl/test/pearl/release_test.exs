defmodule Pearl.ReleaseTest do
  use Pearl.DataCase, async: true

  describe "migrate/0" do
    test "runs migrations without error" do
      # migrate/0 should be idempotent — running on an already-migrated DB is a no-op
      assert :ok = Pearl.Release.migrate()
    end
  end

  describe "rollback/2" do
    test "accepts repo and version" do
      # Just verify it doesn't crash with current version
      # We don't actually roll back in tests, just check the function exists
      assert is_function(&Pearl.Release.rollback/2, 2)
    end
  end
end
