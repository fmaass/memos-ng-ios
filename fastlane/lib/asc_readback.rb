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
end
