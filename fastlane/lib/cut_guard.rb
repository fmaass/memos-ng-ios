# frozen_string_literal: true

# The decisions that keep a TestFlight cut from building the wrong commit or spending a build
# number twice, taken out of the Fastfile so they can be tested without fastlane, git or Apple
# (fastlane/test/cut_guard_test.rb). The Fastfile's lanes call these as their first statements and
# hand in the side effects as callables; a refusal raises CutGuard::Refusal before any later
# callable is reached, and its message carries "CUT-GUARD-VERDICT=<verdict>" so the cut's Mac half
# can tell a spent number from a proof that could not be made.
#
# Verdicts: provenance, project, usage, no-unspent-proof, claim-failed, pair-mismatch, spent,
# unproven.
module CutGuard
  NO_SUCH_BUILD = "App Store Connect has no such build" # AscReadback.verdict's answer for a nil build
  VERDICT = "CUT-GUARD-VERDICT"
  MARKERS_REFUSED = 20 # scripts/release/cut-markers.sh's exit for a refusal by the markers
  SHA = /\A[0-9a-f]{40}\z/.freeze
  VERSION_KEY = /^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/.freeze
  BUILD_KEY = /^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/.freeze

  class Refusal < StandardError
    attr_reader :verdict

    def initialize(verdict, message)
      @verdict = verdict
      super("#{message} [#{VERDICT}=#{verdict}]")
    end
  end

  def self.refuse!(verdict, message)
    raise Refusal.new(verdict, message)
  end

  # The release checkout must be clean and at exactly the commit asked for. The sha must be the full
  # 40 characters: an abbreviation never matches and must not be "helped" by a prefix match.
  # head and status are callables (git rev-parse HEAD, git status --porcelain), read only once the
  # sha itself is well formed.
  def self.provenance!(expected_sha:, head:, status:)
    sha = expected_sha.to_s.strip
    refuse!("provenance", "expected_sha: is required - the commit this build MUST be built from") if sha.empty?
    refuse!("provenance", "expected_sha: must be the full 40-character lowercase sha (got #{sha.inspect})") unless sha.match?(SHA)
    tree = status.call.to_s
    refuse!("provenance", "provenance: the release checkout is not clean:\n#{tree}") unless tree.strip.empty?
    actual = head.call.to_s.strip
    unless actual == sha
      refuse!("provenance", "provenance: HEAD is #{actual}, expected_sha is #{sha} - refusing to build a commit nobody asked for")
    end
    actual
  end

  # The app target's pair: its first uncommented occurrence (the same reading as scripts/release/cut-*.sh).
  def self.version_pair(project_yml)
    version = project_yml[VERSION_KEY, 1].to_s
    build = project_yml[BUILD_KEY, 1].to_s
    unless valid_pair?(version, build)
      refuse!("project", "project.yml names no version pair (read #{version.inspect} #{build.inspect})")
    end
    [version, build]
  end

  def self.valid_pair?(version, build)
    version.to_s.match?(/\A\d+\.\d+\.\d+\z/) && build.to_s.match?(/\A\d+\z/)
  end

  # One call of cut-markers.sh through runner.call(*argv) -> [exit code, output]. Its own refusal
  # (exit 20) is `refused`; anything else non-zero (no flock, the lock ceiling, an unwritable
  # directory) is `failed`.
  def self.markers!(runner, argv, refused:, failed:)
    code, output = runner.call(*argv)
    return output if code == 0

    verdict = code == MARKERS_REFUSED ? refused : failed
    refuse!(verdict, "cut-markers #{argv.first} REFUSED (exit #{code}): #{output.to_s.strip}")
  end

  # beta: provenance (only when expected_sha: was passed at all), the claim, the archive, the
  # archive's pair against the claimed pair, the upload. A wrong commit never spends a number, and
  # a stale project never uploads a number nobody claimed.
  def self.beta(expected_sha:, head:, status:, project_yml:, runner:, archive:, archived_pair:, upload:)
    provenance!(expected_sha: expected_sha, head: head, status: status) unless expected_sha.nil?
    claimed = version_pair(project_yml.call)
    markers!(runner, ["claim", *claimed], refused: "no-unspent-proof", failed: "claim-failed")
    archive.call
    archived = Array(archived_pair.call).map(&:to_s)
    unless archived == claimed
      refuse!("pair-mismatch", "the archive is #{archived[0]} (#{archived[1]}) but #{claimed[0]} " \
                               "(#{claimed[1]}) was claimed - a stale project; nothing uploaded")
    end
    upload.call(*claimed)
    claimed
  end

  # prove_unused: asc.call -> [status, message] from the attach read-back. Only "no such build"
  # writes a proof (cut-markers.sh prove, which refuses while the pair is spent); a build App Store
  # Connect already holds is a spent number; any other answer proves nothing either way.
  def self.prove(version:, build:, asc:, head:, runner:)
    refuse!("usage", "prove_unused needs version:<x.y.z> build:<n> (got #{version.inspect} #{build.inspect})") unless valid_pair?(version, build)
    status, message = asc.call
    message = message.to_s
    if status == :fail && message == NO_SUCH_BUILD
      markers!(runner, ["prove", version.to_s, build.to_s, head.call.to_s.strip], refused: "spent", failed: "unproven")
    elsif %i[ok wait].include?(status) || message.start_with?("build ")
      refuse!("spent", "NOT PROVEN UNUSED: App Store Connect already holds #{version} (#{build}): #{message}")
    else
      refuse!("unproven", "NOT PROVEN UNUSED: #{version} (#{build}): #{message}")
    end
  end
end
