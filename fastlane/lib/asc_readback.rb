# frozen_string_literal: true

# MEMNG-182: the verdict half of the App Store Connect attach read-back.
#
# Pure on purpose. `upload_to_testflight` exits 0 on its own success, and the `household` group
# was created without `hasAccessToAllBuilds` (Apple's API refuses to turn that on afterwards), so
# a processed-but-unattached build is invisible to every tester -- 1.0.2 (8) and 1.0.3 (9) both
# shipped that way and were only found by hand. The decision that says "the household can
# actually see this build" therefore has to be testable without talking to Apple; the Spaceship
# calls live in the thin Fastfile adapter that feeds this function.
module AscReadback
  module ProcessingState
    VALID = "VALID"
  end

  module InternalState
    READY_FOR_BETA_TESTING = "READY_FOR_BETA_TESTING"
    IN_BETA_TESTING = "IN_BETA_TESTING"
  end

  # build           - nil when ASC has no such build, else an object with #id and #processing_state.
  # group_build_ids - the build ids the beta group ITSELF lists. Deliberately the group-side
  #                   relationship rather than the build's own groups: that is the direction a
  #                   tester's TestFlight reads, and the direction the lost releases lacked.
  # beta_detail     - nil, or an object with #internal_build_state.
  #
  # Returns [:ok | :wait | :fail, message]. :wait is only ever READY_FOR_BETA_TESTING, the
  # transient state between the attach landing and the build becoming visible; every other
  # unexpected state is a failure that names what was observed.
  def self.verdict(build:, group_build_ids:, beta_detail:, group_name: "household")
    return [:fail, "App Store Connect has no such build"] if build.nil?

    state = build.processing_state
    unless state == ProcessingState::VALID
      return [:fail, "build #{build.id} processingState is #{state.inspect}, expected #{ProcessingState::VALID.inspect}"]
    end

    ids = Array(group_build_ids).map(&:to_s)
    unless ids.include?(build.id.to_s)
      return [:fail, "build #{build.id} is NOT attached to the #{group_name} group " \
                     "(the group lists #{ids.size} build(s)) - no tester can see it"]
    end

    internal = beta_detail && beta_detail.internal_build_state
    case internal
    when InternalState::IN_BETA_TESTING
      [:ok, "build #{build.id} is VALID, attached to #{group_name}, and #{internal}"]
    when InternalState::READY_FOR_BETA_TESTING
      [:wait, "build #{build.id} is attached to #{group_name} but still #{internal}"]
    else
      [:fail, "build #{build.id} internalBuildState is #{internal.inspect}, " \
              "expected #{InternalState::IN_BETA_TESTING.inspect}"]
    end
  end

  # The wall-clock budget for the READY_FOR_BETA_TESTING poll. Returns the seconds to wait before
  # the next read-back, or nil when the budget is spent and the lane must give up.
  #
  # nil the moment a further cadence step would not finish inside the deadline. Checking only
  # "has the deadline passed?" after the sleep is not a bound: a :wait observed one second before
  # it still sleeps a full interval and issues another request, so a 300s budget quietly becomes
  # 320s plus a round trip. Here the last iteration skips the sleep and times out instead, and no
  # request is ever issued at or after the deadline.
  def self.next_wait(now:, deadline:, interval:)
    remaining = deadline - now
    return nil if remaining <= interval

    interval
  end


  # Whether another read-back may be STARTED right now.
  #
  # Re-checked immediately before every request, not only after the previous one: a sleep can
  # overshoot -- a loaded build host or a slow round trip wakes up later than asked -- and the
  # budget must not be spent by a request that began after it had already run out.
  #
  # Scope, deliberately: this bounds when a request STARTS. A request already in flight can still
  # FINISH after the deadline, which is inherent to any network call and is not what this guard
  # is for; bounding that would mean cancelling an in-flight HTTP request, which Spaceship does
  # not expose and which would not make the read-back any more truthful.
  def self.may_request?(now:, deadline:)
    now < deadline
  end
end
