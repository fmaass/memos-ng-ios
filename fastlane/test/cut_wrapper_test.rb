# frozen_string_literal: true

# The Mac half's lock-and-deadline wrapper, run for real: its Ruby text is read out of
# bin/testflight-cut-remote.sh (LOCK_AND_BUDGET, through the script's MEMOS_CUT_SOURCE_ONLY=1 mode)
# and executed as `ruby -e <text> <lock> <deadline epoch> <grace> <reap> <command…>`, exactly as
# the script's main runs it. Nothing here is a stub of the wrapper; the commands it guards are
# small shell commands that record whether they ran.
#
# Run (from the repository root): ruby fastlane/test/cut_wrapper_test.rb
# CUT_REMOTE_SCRIPT=<path> reads the wrapper from another copy of the script (a RED run against an
# older revision).
require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class CutWrapperTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = ENV.fetch("CUT_REMOTE_SCRIPT", File.join(ROOT, "bin/testflight-cut-remote.sh"))
  WRAPPER = begin
    out, status = Open3.capture2({ "MEMOS_CUT_SOURCE_ONLY" => "1" }, "bash", "-c",
                                 '. "$1" >/dev/null 2>&1; printf "%s" "$LOCK_AND_BUDGET"', "_", SCRIPT,
                                 err: File::NULL)
    raise "could not read LOCK_AND_BUDGET from #{SCRIPT}" unless status.success? && !out.empty?

    out
  end

  def setup
    @dir = Dir.mktmpdir("cut-wrapper-test")
    @ran = File.join(@dir, "ran")
    @lock = File.join(@dir, "cut.lock")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Runs the real wrapper; returns [exit code, stdout, stderr, seconds it took].
  def wrap(deadline, *command, grace: 1, reap: 1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3({ "MEMOS_CUT_SOURCE_ONLY" => nil }, RbConfig.ruby, "-e", WRAPPER,
                                      @lock, deadline.to_s, grace.to_s, reap.to_s, *command)
    [status.exitstatus, out, err, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def record_cmd(rest = "exit 0")
    ["/bin/sh", "-c", "touch '#{@ran}'; #{rest}"]
  end

  def test_an_expired_deadline_with_a_free_lock_launches_nothing
    code, out, err, = wrap(Time.now.to_i - 5, *record_cmd)
    refute File.exist?(@ran), "the cut ran although its deadline had passed (stderr: #{err})"
    assert_equal 76, code
    assert_equal "testflight-cut REMOTE: version=- build=- group=- stage=expired\n", out
    assert_includes err, "deadline"
  end

  def test_a_deadline_reached_exactly_launches_nothing
    code, = wrap(Time.now.to_i, *record_cmd)
    refute File.exist?(@ran)
    assert_equal 76, code
  end

  def test_a_live_deadline_runs_the_cut_and_passes_its_code_through
    code, out, = wrap(Time.now.to_i + 30, *record_cmd("exit 7"))
    assert File.exist?(@ran)
    assert_equal 7, code
    assert_equal "", out
  end

  def test_a_cut_that_ignores_term_is_gone_by_d_plus_grace_plus_reap
    deadline = Time.now.to_i + 2
    code, out, _err, took = wrap(deadline, "/bin/sh", "-c", "trap '' TERM; touch '#{@ran}'; sleep 30",
                                 grace: 1, reap: 1)
    assert File.exist?(@ran)
    assert_equal 124, code
    assert_equal "testflight-cut REMOTE: version=- build=- group=- stage=budget\n", out
    # D + G = D + 2, plus at most one 0.5 s poll and process start-up
    assert_operator Time.now.to_f, :<=, deadline + 2 + 1.0, "ended #{took.round(2)} s after start"
  end

  def test_a_held_lock_at_the_deadline_reports_lock
    File.open(@lock, File::CREAT | File::RDWR) do |held|
      held.flock(File::LOCK_EX)
      code, out, = wrap(Time.now.to_i + 1, *record_cmd)
      refute File.exist?(@ran)
      assert_equal 75, code
      assert_equal "testflight-cut REMOTE: version=- build=- group=- stage=lock\n", out
    end
  end
end
