module Invidious::Jobs
  JOBS = [] of BaseJob

  # shorts-filter: how long to wait before restarting a job whose main loop
  # crashed. Fixed rather than exponential -- these are long-running
  # background loops, not request handlers, so a bounded, predictable retry
  # cadence is preferable to unbounded backoff that could leave a job
  # effectively dead for hours after just a burst of transient failures.
  RESTART_DELAY = 30.seconds

  # Automatically generate a structure that wraps the various
  # jobs' configs, so that the following YAML config can be used:
  #
  # jobs:
  #   job_name:
  #     enabled: true
  #     some_property: "value"
  #
  macro finished
    struct JobsConfig
      include YAML::Serializable

      {% for sc in BaseJob.subclasses %}
        # Voodoo macro to transform `Some::Module::CustomJob` to `custom`
        {% class_name = sc.id.split("::").last.id.gsub(/Job$/, "").underscore %}

        getter {{ class_name }} = {{ sc.name }}::Config.new
      {% end %}

      def initialize
      end
    end
  end

  def self.register(job : BaseJob)
    JOBS << job
  end

  def self.start_all
    JOBS.each do |job|
      # Don't run the main rountine if the job is disabled by config
      next if job.disabled?

      spawn { run_supervised(job) }
    end
  end

  # shorts-filter: every job's `begin` is expected to run forever via its own
  # `loop do`. If that loop raises anything its own rescue blocks don't
  # catch, Crystal just lets the fiber die -- silently, with no restart --
  # and the job never runs again until the whole process restarts. This
  # happened for real on 2026-07-30: a stray DB::PoolRetryAttemptsExceeded
  # killed RefreshFeedsJob, and the subscription feed sat stale for 2.5 days
  # before anyone noticed, because nothing else (playback, the web UI,
  # /api/v1/health) depends on that job succeeding.
  #
  # Restarts the job instead of letting it die, and logs clearly so a crash
  # is visible in the app's own log as "which job, what exception" rather
  # than only as an unlabeled runtime backtrace.
  #
  # Split into run_once (single attempt, no loop) + run_supervised (the
  # forever-retry wrapper) so the crash-handling itself is testable without
  # a spec that runs forever.
  #
  # `job` is deliberately untyped (duck-typed on #begin) rather than
  # `: BaseJob`: a spec double only needs #begin, and if it subclassed
  # BaseJob it would also get pulled into the `BaseJob.subclasses` loop in
  # `macro finished` above, and fail to compile there for unrelated reasons.
  def self.run_once(job) : Nil
    job.begin

    # A job's `begin` should never return -- they all run `loop do`
    # internally -- so reaching here is itself a bug, not a clean exit.
    LOGGER.error("Jobs: #{job.class} returned from its main loop unexpectedly; restarting in #{RESTART_DELAY}.")
  rescue ex
    LOGGER.error("Jobs: #{job.class} crashed and will restart in #{RESTART_DELAY}: #{ex.inspect_with_backtrace}")
  end

  private def self.run_supervised(job : BaseJob) : Nil
    loop do
      run_once(job)
      sleep RESTART_DELAY
    end
  end
end
