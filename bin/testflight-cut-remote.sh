#!/usr/bin/env bash
# testflight-cut-remote.sh — the Mac half of bin/testflight-cut.sh. Never run by hand on the Mac;
# bin/testflight-cut.sh streams it over ONE ssh call:
#   ssh <host> 'bash -s -- <sha> <lane> <deadline> <grace> <reap> <min window>'
#
#   <sha>         the full 40-character commit, already pushed to <release root>/repo.git as refs/cuts/<sha>
#   <lane>        beta | archive_ipa
#   <deadline>    the ABSOLUTE deadline D, UTC epoch seconds, computed by bin/testflight-cut.sh
#                 (start of its ssh leg + budget); everything below, the checkout-lock wait
#                 included, ends by D however late this script started
#   <grace>       seconds between the cut's TERM at D and its KILL
#   <reap>        seconds the killed group is waited for after the KILL
#   <min window>  this script refuses to start (stage=precheck, exit 3) unless more than this many
#                 seconds are left before D
# All four numbers are bin/testflight-cut.sh's constants; this script holds none of its own.
#
# Under the release checkout's OWN lock (<release root>/.cut.lock, held by Ruby's File#flock, since
# the system Ruby is what the Mac's non-interactive shell always has), and before the deadline:
# fetch refs/cuts/<sha> into <release root>/work, check it out detached, prove HEAD is <sha> and
# the checkout is clean, check the 3 GiB floor on the volume holding the checkout, read the
# version pair from that commit's project.yml, source ~/.config/memosng-ci.env with xtrace off
# (values never printed), regenerate the project (bin/generate.sh: the xcodeproj is not committed,
# and generate restores Package.resolved into it), then
#   beta:         fastlane prove_unused version:<v> build:<b>   (a refusal ends the run before any
#                                                                archive: exit 20 when the number is
#                                                                spent, 21 when it is not proven unused)
#                 fastlane beta expected_sha:<sha>              (claims the number first)
#                 fastlane verify_attach version:<v> build:<b>
#   archive_ipa:  fastlane archive_ipa expected_sha:<sha>       (no proof, no claim, no upload)
# The Fastfile takes the estate-wide release lock itself; this script never does, and never
# touches the Mac gate's locks or devices.
#
# The deadline is enforced HERE, on the Mac, because only here can the whole cut be stopped: the
# cut runs in its own process group, which gets TERM at D (fastlane's own cleanup — the release
# lock — runs on TERM), KILL at D + <grace>, and is gone by D + <grace> + <reap>.
#
# Output: the cut's own output, then one report line the local half reads:
#   testflight-cut REMOTE: version=<v> build=<n> group=<group> stage=<precheck|generate|prove|fastlane|verify>
#   (the wrapper adds stage=lock with exit 75, stage=expired with exit 76 and stage=budget with
#   exit 124, version=- build=-)
# Exit: the failing step's code (fastlane's, generate's); 20 when prove_unused found the number
# spent, 21 when it could not prove it unused; 2 for bad arguments; 3 when a precondition failed
# before anything ran (3 too when too little was left before the deadline to start); 75 when the
# checkout lock was still held at the deadline; 124 when the deadline passed.
#
# bash 3.2 and the system Ruby (2.6) compatible. MEMOS_CUT_SOURCE_ONLY=1 defines the bodies and
# runs nothing — tests/gate/testflight-cut-test.sh reads CUT_BODY that way and runs it against a
# throwaway release root; nothing sets it in a real cut.

main() {
  set +x
  set -u
  local sha="${1:-}" lane="${2:-}" deadline="${3:-}" grace="${4:-}" reap="${5:-}" window="${6:-}" now
  local root=/Users/fabian/build/memos-ng-ios/release
  local env_file="$HOME/.config/memosng-ci.env"

  if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "testflight-cut: the sha must be the full 40-character commit (got '$sha')" >&2
    echo "testflight-cut REMOTE: version=- build=- group=- stage=precheck"
    return 2
  fi
  case "$lane" in beta|archive_ipa) ;; *)
    echo "testflight-cut: the lane must be beta or archive_ipa (got '$lane')" >&2
    echo "testflight-cut REMOTE: version=- build=- group=- stage=precheck"
    return 2 ;;
  esac
  local v bad=0
  printf '%s' "$deadline" | grep -Eq '^[1-9][0-9]{0,10}$' || bad=1
  for v in "$grace" "$reap" "$window"; do
    printf '%s' "$v" | grep -Eq '^[0-9]{1,6}$' || bad=1
  done
  if [ "$bad" -ne 0 ]; then
    echo "testflight-cut: needs <deadline epoch> <grace s> <reap s> <min window s> (got '$deadline' '$grace' '$reap' '$window')" >&2
    echo "testflight-cut REMOTE: version=- build=- group=- stage=precheck"
    return 2
  fi
  now="$(date +%s)"
  if [ "$now" -ge $((deadline - window)) ]; then
    echo "testflight-cut: too late to start: $((deadline - now)) s left before the deadline $deadline, need more than $window - nothing ran" >&2
    echo "testflight-cut REMOTE: version=- build=- group=- stage=precheck"
    return 3
  fi
  echo "testflight-cut: started $((deadline - now)) s before the deadline $deadline"

  ruby -e "$LOCK_AND_BUDGET" "$root/.cut.lock" "$deadline" "$grace" "$reap" \
    /bin/bash -c "$CUT_BODY" testflight-cut-body "$sha" "$lane" "$root" "$env_file" fastlane \
    </dev/null
}

# Runs under the lock. $1 sha, $2 lane, $3 release root, $4 env file, $5 fastlane command.
read -r -d '' CUT_BODY <<'BODY'
set +x
set -u
sha="$1"; lane="$2"; root="$3"; env_file="$4"; fastlane_cmd="$5"
work="$root/work"
group=household
version=-
build=-
precheck() {
  echo "testflight-cut: $1" >&2
  echo "testflight-cut REMOTE: version=- build=- group=- stage=precheck"
  exit 3
}
report() { # STAGE EXIT
  echo "testflight-cut REMOTE: version=$version build=$build group=$group stage=$1"
  exit "$2"
}
[ -d "$work/.git" ] || precheck "no release checkout at $work"
cd "$work" || precheck "cannot enter $work"
git fetch --quiet "$root/repo.git" "refs/cuts/$sha" || precheck "fetch of refs/cuts/$sha from $root/repo.git failed"
git checkout --quiet --detach "$sha" || precheck "checkout of $sha failed"
head="$(git rev-parse HEAD)"
[ "$head" = "$sha" ] || precheck "provenance: the release checkout is at $head, not $sha"
[ -z "$(git status --porcelain)" ] || precheck "the release checkout $work is not clean"
[ -f "$env_file" ] || precheck "no env file at $env_file"
# The volume is shared with the gate's lanes and another app's release; stopping here spends
# nothing (no archive, no upload, no build number).
avail="$(df -g "$work" | awk 'NR==2 {print $4}')"
case "$avail" in ''|*[!0-9]*) precheck "cannot read the free space of the volume holding $work" ;; esac
echo "testflight-cut: avail_GiB=$avail"
[ "$avail" -ge 3 ] || precheck "DISK FLOOR: $avail GiB free on the volume holding $work, need 3"
# The app target's pair is the first occurrence; the anchor keeps a comment naming a key from counting.
tree_version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
tree_build=$(sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"?([^"[:space:]]*)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
printf '%s' "$tree_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' && printf '%s' "$tree_build" | grep -Eq '^[0-9]+$' ||
  precheck "project.yml at $sha names no version pair (read '${tree_version}' '${tree_build}')"
version="$tree_version"
build="$tree_build"
set -a
. "$env_file"
set +a
set +x
export PATH="/opt/homebrew/bin:$PATH" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
echo "testflight-cut: bin/generate.sh in $work"
./bin/generate.sh </dev/null
rc=$?
[ "$rc" -eq 0 ] || report generate "$rc"
if [ "$lane" = beta ]; then
  echo "testflight-cut: fastlane prove_unused version:$version build:$build"
  # The lane's refusal names its verdict (fastlane/lib/cut_guard.rb): only "spent" says the number
  # is gone; any other failure (App Store Connect unreachable, no app, the markers' lock) proves
  # nothing either way. The LAST token is the guard's own, after any text it quoted.
  prove_out="$(mktemp "${TMPDIR:-/tmp}/testflight-cut-prove.XXXXXX")" || precheck "cannot create a temporary file"
  "$fastlane_cmd" prove_unused "version:$version" "build:$build" 2>&1 | tee "$prove_out"
  rc=${PIPESTATUS[0]}
  verdict="$(grep -o 'CUT-GUARD-VERDICT=[a-z-]*' "$prove_out" | tail -n 1)"
  rm -f "${prove_out:?}"
  if [ "$rc" -ne 0 ]; then
    if [ "$verdict" = CUT-GUARD-VERDICT=spent ]; then
      echo "testflight-cut: $version ($build) is spent (prove_unused exit $rc) - nothing archived"
      report prove 20
    fi
    echo "testflight-cut: $version ($build) is not proven unused (prove_unused exit $rc, ${verdict:-no verdict}) - nothing archived"
    report prove 21
  fi
fi
rm -rf "$work/build/MemosNG.xcarchive" "$work/build/MemosNG.ipa"
echo "testflight-cut: fastlane $lane expected_sha:$sha in $work"
"$fastlane_cmd" "$lane" "expected_sha:$sha"
rc=$?
[ "$rc" -eq 0 ] || report fastlane "$rc"
[ "$lane" = beta ] || report fastlane 0
"$fastlane_cmd" verify_attach "version:$version" "build:$build"
report verify "$?"
BODY

# ARGV: lock path, deadline (UTC epoch seconds), grace seconds, reap seconds, cut command…
# Under the lock: the cut, in its own process group, TERMed at the deadline (or when this wrapper
# is told to stop), KILLed GRACE seconds after that and waited for REAP seconds more. The lock is
# released only after it is gone. The absolute deadline is read against the wall clock ONCE, here,
# and kept on the monotonic clock from then on.
# Exit: the cut's code (128+signal when it was killed), 75 when the lock was still held at the
# deadline, 76 (stage=expired) when the deadline had passed once the lock was held - nothing is
# launched then -, 124 when the deadline passed during the cut, 128+signal when this wrapper itself
# was told to stop. The stop is never later than D: TERM at D at the latest, KILL GRACE after the
# TERM, the reap over by TERM + GRACE + REAP. Polling adds at most 0.5 s (the run loop) and 0.2 s
# (the reap loop). fastlane/test/cut_wrapper_test.rb runs this text for real.
read -r -d '' LOCK_AND_BUDGET <<'RUBY'
lock_path, deadline_epoch, grace, reap, *cut_cmd = ARGV
GRACE = Integer(grace)
REAP = Integer(reap)
clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
deadline = clock.call + (Integer(deadline_epoch) - Time.now.to_f)
$stdout.sync = true
# The ssh session may be gone when this wrapper is told to stop: a write to it must not end the
# wrapper before the cut's group is gone.
say = lambda do |io, line|
  begin
    io.puts(line)
  rescue SystemCallError, IOError
    nil
  end
end

lock = File.open(lock_path, File::CREAT | File::RDWR, 0o644)
announced = false
until lock.flock(File::LOCK_EX | File::LOCK_NB)
  if clock.call >= deadline
    say.call($stderr, "testflight-cut: the release checkout lock #{lock_path} was still held at the deadline")
    say.call($stdout, "testflight-cut REMOTE: version=- build=- group=- stage=lock")
    exit 75
  end
  say.call($stderr, "testflight-cut: waiting for the release checkout lock #{lock_path}") unless announced
  announced = true
  sleep 2
end
# The deadline again, with the lock held and nothing launched yet: the shell's start check can be
# followed by any stall (a slow ruby start, a stopped process resumed), and a cut launched after D
# runs where the controller no longer holds the estate lock for it.
if clock.call >= deadline
  say.call($stderr, "testflight-cut: the deadline passed before the cut could start - nothing ran")
  say.call($stdout, "testflight-cut REMOTE: version=- build=- group=- stage=expired")
  exit 76
end
lock.truncate(0)
lock.write("pid=#{Process.pid} at=#{Time.now.utc}\n")
lock.flush

signal_group = lambda do |pid, sig|
  begin
    Process.kill(sig, -pid)
  rescue SystemCallError
    nil
  end
end
interrupted = nil
current = nil
%w[HUP INT TERM].each do |name|
  Signal.trap(name) do
    interrupted ||= Signal.list[name]
    if current
      current[:term_at] ||= [clock.call, deadline].min # a signal never moves the stop past D
      signal_group.call(current[:pid], "TERM")
    end
  end
end

# The lock's descriptor is close-on-exec (Ruby's default), so the cut cannot leak it into a
# long-lived helper process; this process holds it until the cut's group is gone.
pid = Process.spawn(*cut_cmd, pgroup: true)
current = { pid: pid, term_at: nil, timed_out: false }
current[:term_at] = [clock.call, deadline].min if interrupted
signal_group.call(pid, "TERM") if current[:term_at]
stopped_code = -> { current[:timed_out] ? 124 : 128 + interrupted.to_i }
code = nil
loop do
  done, status = Process.waitpid2(pid, Process::WNOHANG)
  if done
    # A stopped cut's leader can die on TERM while a descendant ignores it: nothing of the group
    # may outlive the lock.
    if current[:term_at]
      signal_group.call(pid, "KILL")
      code = stopped_code.call
    else
      code = status.exitstatus || 128 + (status.termsig || 0)
    end
    break
  end
  now = clock.call
  if current[:term_at].nil? && now >= deadline
    say.call($stderr, "testflight-cut: the cut ran past its deadline - stopping it")
    current[:timed_out] = true
    current[:term_at] = deadline # KILL at D + GRACE, not at the instant this poll noticed D
    signal_group.call(pid, "TERM")
  elsif current[:term_at] && now >= current[:term_at] + GRACE
    signal_group.call(pid, "KILL")
    reap_until = current[:term_at] + GRACE + REAP # absolute: by D + G at the latest
    until Process.waitpid(pid, Process::WNOHANG)
      if clock.call >= reap_until
        Process.detach(pid)
        break
      end
      sleep 0.2
    end
    code = stopped_code.call
    break
  end
  sleep 0.5
end
say.call($stdout, "testflight-cut REMOTE: version=- build=- group=- stage=budget") if current[:timed_out]
exit(code)
RUBY

[ -n "${MEMOS_CUT_SOURCE_ONLY:-}" ] || main "$@" </dev/null
