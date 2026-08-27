# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/asc_readback_test.rb
require "minitest/autorun"
require "asc_readback"

FakeBuild = Struct.new(:id, :processing_state)
FakeBetaDetail = Struct.new(:internal_build_state)

class AscReadbackTest < Minitest::Test
  ATTACHED = "IN_BETA_TESTING"

  def valid_build
    FakeBuild.new("11111111-2222-3333-4444-555555555555", "VALID")
  end

  def verdict(build:, group_build_ids: [], beta_detail: FakeBetaDetail.new(ATTACHED))
    AscReadback.verdict(build: build, group_build_ids: group_build_ids, beta_detail: beta_detail)
  end

  def test_build_not_found_fails
    status, message = verdict(build: nil)
    assert_equal(:fail, status)
    assert_match(/no such build/i, message)
  end

  def test_processing_state_not_valid_fails
    %w[PROCESSING INVALID FAILED].each do |state|
      build = FakeBuild.new("B1", state)
      status, message = verdict(build: build, group_build_ids: ["B1"])
      assert_equal(:fail, status, "#{state} must not pass the read-back")
      assert_match(/processingState is "#{state}"/, message)
    end
  end

  def test_valid_but_absent_from_group_fails
    build = valid_build
    status, message = verdict(build: build, group_build_ids: ["some-other-build"])
    assert_equal(:fail, status)
    assert_match(/NOT attached to the household group/, message)
    assert_match(/#{build.id}/, message)
  end

  def test_valid_and_group_empty_fails
    status, message = verdict(build: valid_build, group_build_ids: [])
    assert_equal(:fail, status)
    assert_match(/NOT attached/, message)
  end

  def test_attached_but_ready_for_beta_testing_waits
    build = valid_build
    status, message = verdict(build: build, group_build_ids: [build.id],
                              beta_detail: FakeBetaDetail.new("READY_FOR_BETA_TESTING"))
    assert_equal(:wait, status)
    assert_match(/READY_FOR_BETA_TESTING/, message)
  end

  def test_attached_and_in_beta_testing_is_ok
    build = valid_build
    status, message = verdict(build: build, group_build_ids: ["another", build.id])
    assert_equal(:ok, status)
    assert_match(/#{ATTACHED}/, message)
  end

  def test_attached_but_unexpected_internal_state_fails
    build = valid_build
    status, message = verdict(build: build, group_build_ids: [build.id],
                              beta_detail: FakeBetaDetail.new("MISSING_EXPORT_COMPLIANCE"))
    assert_equal(:fail, status)
    assert_match(/internalBuildState is "MISSING_EXPORT_COMPLIANCE"/, message)
  end

  def test_attached_but_no_beta_detail_fails
    build = valid_build
    status, message = verdict(build: build, group_build_ids: [build.id], beta_detail: nil)
    assert_equal(:fail, status)
    assert_match(/internalBuildState is nil/, message)
  end
end
