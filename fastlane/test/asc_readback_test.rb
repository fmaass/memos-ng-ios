# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/asc_readback_test.rb
require "minitest/autorun"
require "asc_readback"

FakeBuild = Struct.new(:id, :processing_state)
FakeBetaDetail = Struct.new(:internal_build_state)

class AscReadbackTest < Minitest::Test
  ATTACHED = "IN_BETA_TESTING"
  BUDGET = 300
  CADENCE = 20

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


  # MEMNG-182 blocker 2: the READY poll must be bounded by its own deadline.
  def test_next_wait_yields_the_cadence_while_the_budget_holds
    now = Time.at(1_000)
    assert_equal(20, AscReadback.next_wait(now: now, deadline: now + 300, interval: 20))
    assert_equal(20, AscReadback.next_wait(now: now, deadline: now + 21, interval: 20))
  end

  def test_next_wait_stops_when_one_more_step_would_not_fit
    now = Time.at(1_000)
    assert_nil(AscReadback.next_wait(now: now, deadline: now + 20, interval: 20))
    assert_nil(AscReadback.next_wait(now: now, deadline: now + 5, interval: 20))
  end

  def test_next_wait_stops_once_the_deadline_is_reached_or_past
    now = Time.at(1_000)
    assert_nil(AscReadback.next_wait(now: now, deadline: now, interval: 20))
    assert_nil(AscReadback.next_wait(now: now, deadline: now - 60, interval: 20))
  end

  # Replaying the lane's real loop against the real function: the property that matters is that no
  # read-back is ever issued at or after the deadline, however many times it goes round.
  def test_the_poll_schedule_never_reaches_the_deadline
    start = Time.at(1_000)
    deadline = start + AscReadbackTest::BUDGET
    now = start
    polls = [now]

    # Bounded on purpose: a next_wait that never returns nil is exactly the regression under test,
    # and an unbounded replay would hang the suite instead of failing it.
    gave_up = false
    (2 * BUDGET / CADENCE).to_i.times do
      wait = AscReadback.next_wait(now: now, deadline: deadline, interval: CADENCE)
      if wait.nil?
        gave_up = true
        break
      end

      now += wait
      polls << now
    end

    assert(gave_up, "next_wait never gave up: the poll would run past its budget forever")
    assert_operator(polls.size, :>, 1, "the poll must actually retry, or it is not a poll")
    assert_operator(polls.last, :<, deadline, "the last read-back must be issued before the deadline")
    assert(polls.each_cons(2).all? { |a, b| (b - a) == CADENCE }, "the cadence must stay put")
  end


  # MEMNG-182 blocker: the budget is re-checked immediately BEFORE each request, because a sleep
  # can overshoot and next_wait alone only decides whether to sleep, not whether the request that
  # follows the sleep is still inside the budget.
  def test_may_request_allows_a_request_before_the_deadline
    now = Time.at(1_000)
    assert(AscReadback.may_request?(now: now, deadline: now + 1))
    assert(AscReadback.may_request?(now: now, deadline: now + BUDGET))
  end

  def test_may_request_refuses_at_and_after_the_deadline
    now = Time.at(1_000)
    refute(AscReadback.may_request?(now: now, deadline: now), "a request AT the deadline is late")
    refute(AscReadback.may_request?(now: now, deadline: now - 1))
  end

  # Replays the lane's loop with a clock that overshoots every sleep, which is what a loaded build
  # host actually does. No request may be STARTED at or after the deadline however far it drifts.
  #
  # The overshoot is SWEPT rather than fixed: next_wait's own margin already absorbs most values,
  # so a single hand-picked overshoot can pass with the pre-request guard removed and pin nothing.
  # Somewhere in this range the drift lands exactly on the deadline, and that is the case the
  # guard exists for.
  def test_no_overshooting_sleep_ever_starts_a_request_at_or_after_the_deadline
    (1..25).each do |overshoot|
      start = Time.at(1_000)
      deadline = start + BUDGET
      now = start
      requests = []

      (4 * BUDGET / CADENCE).to_i.times do
        break unless AscReadback.may_request?(now: now, deadline: deadline)

        requests << now
        wait = AscReadback.next_wait(now: now, deadline: deadline, interval: CADENCE)
        break if wait.nil?

        now += wait + overshoot
      end

      late = requests.reject { |at| at < deadline }
      assert_operator(requests.size, :>, 1, "overshoot #{overshoot}: the poll must actually retry")
      assert_empty(late.map { |at| at - start },
                   "overshoot #{overshoot}s: a read-back was started at or after the deadline")
    end
  end
end
