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


  # MEMNG-173 blocker 3: the two fields default independently. Defaulting them as a pair files a
  # release's symbols under a version that was never shipped, which is silent until a crash needs
  # them and the directory is empty.
  ARCHIVE_VERSION = "1.0.1"
  ARCHIVE_BUILD = "7"

  def label(version:, build:)
    DsymStore.release_label(version: version, build: build,
                            archive_version: ARCHIVE_VERSION, archive_build: ARCHIVE_BUILD)
  end

  def test_both_supplied_are_both_kept
    assert_equal(["1.0.4", "11"], label(version: "1.0.4", build: "11"))
  end

  def test_a_missing_build_defaults_alone_and_leaves_the_supplied_version_alone
    assert_equal(["1.0.4", ARCHIVE_BUILD], label(version: "1.0.4", build: ""))
  end

  def test_a_missing_version_defaults_alone_and_leaves_the_supplied_build_alone
    assert_equal([ARCHIVE_VERSION, "11"], label(version: "", build: "11"))
  end

  def test_both_missing_fall_back_to_the_archive
    assert_equal([ARCHIVE_VERSION, ARCHIVE_BUILD], label(version: nil, build: nil))
  end

  def test_whitespace_only_counts_as_missing
    assert_equal([ARCHIVE_VERSION, ARCHIVE_BUILD], label(version: "  ", build: "\t"))
  end

  def test_the_label_is_always_strings
    version, build = DsymStore.release_label(version: nil, build: 11,
                                             archive_version: 1.01, archive_build: 7)
    assert_kind_of(String, version)
    assert_kind_of(String, build)
    assert_equal("11", build)
  end
end
