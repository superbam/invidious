# Tracks recent signs that YouTube has changed something Invidious relies on
# to pull video data (missing JSON fields the parser expects, YouTube handing
# back the wrong video, etc). A single occurrence can just be a fluke, but
# several within one statistics window (see StatisticsRefreshJob) is the same
# kind of signal that normally prompts an Invidious/companion release, so we
# surface it to admins instead of letting it look like a one-off crash.
module Invidious::ExtractionHealth
  extend self

  # Failures observed during the current window. Reset alongside the
  # playback stats tracker in StatisticsRefreshJob#refresh_stats.
  @@failures = 0_i64

  # Failures within a single window before we consider YouTube-access
  # degraded enough to be worth telling admins about.
  THRESHOLD = 5

  def report_failure : Nil
    @@failures += 1
  end

  def degraded? : Bool
    @@failures >= THRESHOLD
  end

  def reset : Nil
    @@failures = 0_i64
  end
end
