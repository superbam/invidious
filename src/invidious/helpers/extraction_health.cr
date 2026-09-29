# Tracks recent signs that YouTube has changed something Invidious relies on
# to pull video data (missing JSON fields the parser expects, YouTube handing
# back the wrong video, etc). A single occurrence can just be a fluke, but
# several within one window is the same kind of signal that normally prompts
# an Invidious/companion release, so we surface it to admins instead of
# letting it look like a one-off crash.
module Invidious::ExtractionHealth
  extend self

  # Length of a counting window. This is tracked here rather than relying on
  # StatisticsRefreshJob, which only runs when statistics_enabled is set;
  # without it the counter would never reset and the flag would stick.
  WINDOW = 10.minutes

  # Failures within a single window before we consider YouTube-access
  # degraded enough to be worth telling admins about.
  THRESHOLD = 5

  @@failures = 0_i64
  @@window_start = Time.monotonic

  # Failure count from the last completed window, so the flag stays visible
  # for a full window after a burst instead of vanishing on rollover.
  @@previous_failures = 0_i64

  def report_failure : Nil
    roll_window
    @@failures += 1
  end

  def degraded? : Bool
    roll_window
    @@failures >= THRESHOLD || @@previous_failures >= THRESHOLD
  end

  def reset : Nil
    @@failures = 0_i64
    @@previous_failures = 0_i64
    @@window_start = Time.monotonic
  end

  private def roll_window : Nil
    elapsed = Time.monotonic - @@window_start
    return if elapsed < WINDOW

    # If more than one full window passed with no activity, the previous
    # window was empty.
    @@previous_failures = elapsed < WINDOW * 2 ? @@failures : 0_i64
    @@failures = 0_i64
    @@window_start = Time.monotonic
  end
end
