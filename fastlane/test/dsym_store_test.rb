# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/dsym_store_test.rb
require "minitest/autorun"
require "dsym_store"

class DsymStoreTest < Minitest::Test
  STORES = [["janus", "/Users/Shared/nas/janus"], ["lexosaurus", "/Volumes/lexosaurus"]].freeze

  def test_primary_is_taken_when_reachable
    status, root, message = DsymStore.choose(STORES) { |_root| true }
    assert_equal(:primary, status)
    assert_equal("/Users/Shared/nas/janus", root)
    assert_match(/janus/, message)
    refute_match(/WARN/, message)
  end

  def test_fallback_is_taken_and_warns_loudly_when_primary_is_gone
    status, root, message = DsymStore.choose(STORES) { |root| root != "/Users/Shared/nas/janus" }
    assert_equal(:fallback, status)
    assert_equal("/Volumes/lexosaurus", root)
    assert_match(/WARN/, message)
    assert_match(/janus/, message)
  end

  def test_no_store_reachable_is_a_failure_not_a_skip
    status, root, message = DsymStore.choose(STORES) { |_root| false }
    assert_equal(:none, status)
    assert_nil(root)
    assert_match(/janus/, message)
    assert_match(/lexosaurus/, message)
    assert_match(/would be lost/, message)
  end
end
