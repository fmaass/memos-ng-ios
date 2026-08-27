# frozen_string_literal: true

# MEMNG-173: a store-reachability probe that cannot outlive its own budget.
#
# The dSYM stores are network mounts. A hung NFS hard mount blocks in an uninterruptible syscall,
# so an in-process guard (Timeout.timeout wrapped around Dir.entries or File.writable?) hangs with
# it -- the timer thread never gets scheduled and the release lane waits forever instead of
# falling back to lexosaurus or failing loudly, which is the whole point of having a fallback.
# The kill therefore has to come from OUTSIDE the blocked process: the probe runs in its own
# process group and the group is SIGKILLed when it overruns, so a shell cannot leave the blocked
# `ls` behind either. macOS ships no timeout(1) and this build host has no coreutils (verified on
# merkur 2026-08-27: both `timeout` and `gtimeout` absent), so the wait is hand-rolled rather than
# delegated to a binary that is not there.
#
# SIGKILL is not the end of the story. A process wedged in an uninterruptible syscall does not die
# until its I/O returns, so a plain blocking `Process.waitpid` after the kill reintroduces exactly
# the hang this module exists to prevent -- same wedge, one line further down. The reap is bounded
# too, and when that budget expires the child is DETACHED and abandoned rather than waited on: a
# stray process is a far smaller problem than a release lane that never returns.
module TimedProbe
  DEFAULT_POLL = 0.05
  DEFAULT_REAP_WINDOW = 2.0

  # True only when `command` exits 0 within `seconds`. A timeout, a non-zero exit and a failure to
  # spawn at all are one answer -- "this store is not usable right now" -- because that is the only
  # distinction the caller acts on.
  #
  # `killer` is injected so the case that matters most (a child that outlives the kill) is
  # reachable in a test without wedging a real mount.
  def self.ok?(command, seconds:, poll: DEFAULT_POLL, reap_window: DEFAULT_REAP_WINDOW,
               clock: -> { Time.now }, killer: method(:kill_group))
    pid = nil
    begin
      pid = Process.spawn(command, pgroup: true, out: File::NULL, err: File::NULL)
      deadline = clock.call + seconds
      loop do
        finished, status = Process.waitpid2(pid, Process::WNOHANG)
        if finished
          pid = nil
          return status.success?
        end
        return false if clock.call >= deadline

        sleep(poll)
      end
    rescue SystemCallError
      false
    ensure
      # Every path that still owns a live child abandons it here -- the timeout, an exception
      # raised mid-wait, anything. This is the production guarantee, not a test convenience.
      abandon(pid, killer: killer, reap_window: reap_window, poll: poll, clock: clock) if pid
    end
  end

  # Kills the process group, then reaps on a bounded budget. A child still unreaped when the
  # budget runs out is detached and forgotten -- never blocked on.
  def self.abandon(pid, killer:, reap_window:, poll:, clock:)
    killer.call(pid)
    deadline = clock.call + reap_window
    loop do
      return if Process.waitpid(pid, Process::WNOHANG)
      if clock.call >= deadline
        Process.detach(pid)
        return
      end

      sleep(poll)
    end
  rescue SystemCallError
    nil
  end

  def self.kill_group(pid)
    Process.kill("KILL", -Process.getpgid(pid))
  rescue SystemCallError
    nil
  end
end
