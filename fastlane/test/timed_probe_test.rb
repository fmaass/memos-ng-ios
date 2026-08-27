# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/timed_probe_test.rb
require "minitest/autorun"
require "tmpdir"
require "timed_probe"

class TimedProbeTest < Minitest::Test
  def test_a_command_that_succeeds_in_time_is_usable
    assert_equal(true, TimedProbe.ok?("/usr/bin/true", seconds: 5))
  end

  def test_a_command_that_fails_is_not_usable
    assert_equal(false, TimedProbe.ok?("/usr/bin/false", seconds: 5))
  end

  def test_a_command_that_cannot_be_spawned_is_not_usable
    assert_equal(false, TimedProbe.ok?("/nonexistent/l5/binary", seconds: 5))
  end

  # The assertion the whole module exists for: a hung mount must not hold the release lane. The
  # probe has to come back on ITS budget, not on the command's.
  def test_a_hanging_command_is_abandoned_at_its_deadline
    started = Time.now
    result = TimedProbe.ok?("sleep 30", seconds: 1)
    elapsed = Time.now - started

    assert_equal(false, result)
    assert_operator(elapsed, :<, 10, "the probe must return on its own deadline, not the command's")
  end

  # Returning on time is only half of it -- an abandoned probe that leaves the blocked process
  # running would pile one up per release. The heartbeat has to stop when the probe gives up.
  def test_the_abandoned_command_is_actually_dead
    path = File.join(Dir.tmpdir, "l5-timedprobe-heartbeat-#{Process.pid}")
    File.delete(path) if File.exist?(path)

    TimedProbe.ok?("while true; do echo tick >> #{path}; sleep 0.1; done", seconds: 1)
    settled = File.exist?(path) ? File.size(path) : 0
    sleep 1
    later = File.exist?(path) ? File.size(path) : 0

    assert_operator(settled, :>, 0, "the probe never actually started the command")
    assert_equal(settled, later, "the command kept running after the probe gave up on it")
  ensure
    # When this test FAILS the command is by definition still running, and merkur is a shared
    # build host with a chronically tight disk -- so the survivor is reaped here rather than left
    # spinning for whoever gates next.
    system("pkill", "-f", File.basename(path.to_s), out: File::NULL, err: File::NULL) if path
    File.delete(path) if path && File.exist?(path)
  end


  # The blocker this module was revised for: a child wedged in an uninterruptible syscall does not
  # die on SIGKILL until its I/O returns, so reaping it with a BLOCKING waitpid puts the hang back
  # one line further down. It must be abandoned instead. The kill is injected as a no-op to reach
  # that case without a wedged mount.
  def test_a_child_that_outlives_the_kill_is_abandoned_not_waited_on
    marker = "l5-outlives-#{Process.pid}"
    started = Time.now
    result = TimedProbe.ok?("sleep 20 # #{marker}", seconds: 0.3, reap_window: 0.5,
                            killer: ->(_pid) {})
    elapsed = Time.now - started

    assert_equal(false, result)
    assert_operator(elapsed, :<, 10,
                    "the probe blocked on a child that outlived the kill instead of abandoning it")
  ensure
    system("pkill", "-f", marker.to_s, out: File::NULL, err: File::NULL) if marker
  end

  # When the reap budget expires the child is detached, and the detach has to actually collect it
  # once it finally exits -- otherwise every timed-out probe leaves a zombie on the build host.
  def test_a_late_exiting_child_is_detached_and_leaves_nothing_behind
    marker = "l5-late-#{Process.pid}"
    result = TimedProbe.ok?("sleep 1 # #{marker}", seconds: 0.2, reap_window: 0.0,
                            killer: ->(_pid) {})
    assert_equal(false, result)

    sleep 2.5
    lingering = `ps -A -o pid=,stat=,command=`.lines.select { |line| line.include?(marker) }
    assert_empty(lingering, "the detached child was left behind: #{lingering.inspect}")
  ensure
    system("pkill", "-f", marker.to_s, out: File::NULL, err: File::NULL) if marker
  end
end
