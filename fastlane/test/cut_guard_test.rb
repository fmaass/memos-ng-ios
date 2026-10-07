# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/cut_guard_test.rb
require "minitest/autorun"
require "cut_guard"

class CutGuardTest < Minitest::Test
  SHA = "1" * 40
  OTHER = "2" * 40
  PROJECT_YML = <<~YML
    targets:
      MemosNG:
        settings:
          base:
            # MARKETING_VERSION: "0.0.1"
            # CURRENT_PROJECT_VERSION: "1"
            MARKETING_VERSION: "2.2.2"
            CURRENT_PROJECT_VERSION: "43"
      MemosShare:
        settings:
          base:
            MARKETING_VERSION: "9.9.9"
            CURRENT_PROJECT_VERSION: "99"
  YML

  # Records every step the guard reaches, in order; each callable answers what the case scripts.
  def setup
    @calls = []
  end

  def head(sha = SHA)
    -> { @calls << :head; sha }
  end

  def status(text = "")
    -> { @calls << :status; text }
  end

  def runner(answers = {})
    lambda do |*argv|
      @calls << [:markers, *argv]
      answers.fetch(argv.first, [0, "cut-markers: ok\n"])
    end
  end

  def run_beta(expected_sha: SHA, head_sha: SHA, tree: "", markers: {}, archived: %w[2.2.2 43], yml: PROJECT_YML)
    CutGuard.beta(
      expected_sha: expected_sha, head: head(head_sha), status: status(tree),
      project_yml: -> { yml }, runner: runner(markers),
      archive: -> { @calls << :archive },
      archived_pair: -> { @calls << :archived_pair; archived },
      upload: ->(version, build) { @calls << [:upload, version, build] }
    )
  end

  def assert_refused(verdict)
    error = assert_raises(CutGuard::Refusal) { yield }
    assert_equal verdict, error.verdict
    assert_includes error.message, "#{CutGuard::VERDICT}=#{verdict}"
    error
  end

  def refute_reached(*steps)
    steps.each do |step|
      refute(@calls.any? { |c| c == step || (c.is_a?(Array) && c.first == step) }, "#{step} was reached: #{@calls.inspect}")
    end
  end

  # --- beta: provenance, then the claim, then the archive, the pair check and the upload ---

  def test_beta_happy_path_runs_every_step_in_order
    assert_equal %w[2.2.2 43], run_beta
    assert_equal [:status, :head, [:markers, "claim", "2.2.2", "43"], :archive, :archived_pair,
                  [:upload, "2.2.2", "43"]], @calls
  end

  def test_beta_wrong_sha_refuses_before_the_claim_and_the_archive
    assert_refused("provenance") { run_beta(expected_sha: OTHER) }
    refute_reached :markers, :archive, :upload
  end

  def test_beta_malformed_sha_refuses_before_reading_git
    ["", "abc", SHA[0, 12], SHA.upcase.tr("1", "A"), " #{SHA}x"].each do |bad|
      @calls = []
      assert_refused("provenance") { run_beta(expected_sha: bad) }
      refute_reached :head, :markers, :archive, :upload
    end
  end

  def test_beta_dirty_checkout_refuses
    assert_refused("provenance") { run_beta(tree: " M project.yml\n") }
    refute_reached :markers, :archive, :upload
  end

  def test_beta_without_expected_sha_skips_provenance_only
    run_beta(expected_sha: nil)
    refute_reached :head, :status
    assert_includes @calls, :archive
  end

  def test_beta_missing_proof_refuses_and_archives_nothing
    error = assert_refused("no-unspent-proof") do
      run_beta(markers: { "claim" => [20, "cut-markers: REFUSED: no unspent proof for 2.2.2 (43)\n"] })
    end
    assert_includes error.message, "no unspent proof"
    refute_reached :archive, :archived_pair, :upload
  end

  def test_beta_spent_claim_refuses_and_archives_nothing
    assert_refused("no-unspent-proof") do
      run_beta(markers: { "claim" => [20, "cut-markers: REFUSED: 2.2.2 (43) was already claimed\n"] })
    end
    refute_reached :archive, :upload
  end

  def test_beta_marker_infrastructure_failure_refuses_and_archives_nothing
    assert_refused("claim-failed") { run_beta(markers: { "claim" => [75, "lock still held\n"] }) }
    refute_reached :archive, :upload
  end

  def test_beta_pair_mismatch_refuses_before_the_upload
    error = assert_refused("pair-mismatch") { run_beta(archived: %w[2.2.2 42]) }
    assert_includes error.message, "2.2.2 (42)"
    assert_includes @calls, :archive
    refute_reached :upload
  end

  def test_beta_project_without_a_pair_refuses_before_the_claim
    assert_refused("project") { run_beta(yml: "targets: {}\n") }
    refute_reached :markers, :archive, :upload
  end

  # --- the version pair: the app target's, never a comment's or the extension's ---

  def test_version_pair_reads_the_first_uncommented_pair
    assert_equal %w[2.2.2 43], CutGuard.version_pair(PROJECT_YML)
  end

  # --- prove: only App Store Connect's "no such build" publishes a proof ---

  def run_prove(asc:, markers: {}, version: "2.2.2", build: "43")
    CutGuard.prove(version: version, build: build, asc: -> { @calls << :asc; asc },
                   head: head, runner: runner(markers))
  end

  def test_prove_no_such_build_writes_the_proof_at_head
    run_prove(asc: [:fail, CutGuard::NO_SUCH_BUILD])
    assert_equal [:asc, :head, [:markers, "prove", "2.2.2", "43", SHA]], @calls
  end

  def test_prove_spent_marker_refuses_as_spent
    assert_refused("spent") do
      run_prove(asc: [:fail, CutGuard::NO_SUCH_BUILD], markers: { "prove" => [20, "already claimed\n"] })
    end
  end

  def test_prove_build_on_app_store_connect_refuses_as_spent_without_a_marker
    [[:ok, "build 9 is VALID, attached to household, and IN_BETA_TESTING"],
     [:wait, "build 9 is attached to household but still READY_FOR_BETA_TESTING"],
     [:fail, "build 9 processingState is \"PROCESSING\", expected \"VALID\""]].each do |answer|
      @calls = []
      assert_refused("spent") { run_prove(asc: answer) }
      refute_reached :markers
    end
  end

  def test_prove_infrastructure_answer_refuses_as_unproven_without_a_marker
    ["App Store Connect has no app live.discomarder.memosng",
     "App Store Connect has no beta group \"household\""].each do |message|
      @calls = []
      assert_refused("unproven") { run_prove(asc: [:fail, message]) }
      refute_reached :markers
    end
  end

  def test_prove_marker_infrastructure_failure_is_unproven_not_spent
    assert_refused("unproven") do
      run_prove(asc: [:fail, CutGuard::NO_SUCH_BUILD], markers: { "prove" => [75, "lock still held\n"] })
    end
  end

  def test_prove_refuses_a_malformed_pair_before_asking
    [["2.2", "43"], ["2.2.2", ""], ["2.2.2", "43a"]].each do |version, build|
      @calls = []
      assert_refused("usage") { run_prove(asc: [:fail, CutGuard::NO_SUCH_BUILD], version: version, build: build) }
      assert_empty @calls
    end
  end

  # --- provenance on its own (archive_ipa's first statement) ---

  def test_provenance_accepts_the_exact_clean_head
    assert_equal SHA, CutGuard.provenance!(expected_sha: SHA, head: head, status: status)
  end

  def test_provenance_refuses_another_head
    assert_refused("provenance") { CutGuard.provenance!(expected_sha: SHA, head: head(OTHER), status: status) }
  end
end
