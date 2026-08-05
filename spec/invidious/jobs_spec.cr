require "../spec_helper"

# Real jobs all run forever via their own `loop do`; these two exist purely
# to exercise the two ways a job can stop without Invidious::Jobs.run_once
# noticing something's wrong: raising, and returning. Plain classes, not
# BaseJob subclasses: run_once is duck-typed on #begin specifically so a
# double doesn't have to subclass BaseJob, which would pull it into the
# BaseJob.subclasses loop in jobs.cr's `macro finished` and fail to compile.
private class CrashingTestJob
  def begin
    raise "boom"
  end
end

private class ReturningTestJob
  def begin
    # Returns immediately instead of looping forever -- also a bug worth
    # catching, since every real job's `begin` is a `loop do`.
  end
end

Spectator.describe "Invidious::Jobs.run_once" do
  it "does not let an exception from the job's begin method escape" do
    Invidious::Jobs.run_once(CrashingTestJob.new)

    # If run_once let "boom" escape, this line is never reached and the
    # example fails with that exception instead of this assertion -- which
    # is exactly the regression this test guards against (see the
    # 2026-07-30 incident: an uncaught exception silently killed
    # RefreshFeedsJob's fiber for 2.5 days with no restart and no log).
    expect(true).to be_true
  end

  it "does not raise when the job's begin method returns instead of looping" do
    Invidious::Jobs.run_once(ReturningTestJob.new)

    expect(true).to be_true
  end
end
