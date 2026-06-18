# frozen_string_literal: true

module MrubyLsp
  # Whether THIS process is confined by the launcher's sandbox — read straight
  # from the kernel, with NO env var and NO argument (both attacker-settable).
  #
  # The launcher applies a seccomp filter as the FINAL confinement step, reached
  # ONLY after the Landlock FS wall went up. So an active seccomp filter is the
  # truthful "I am fully confined" marker. Landlock itself is intentionally NOT
  # introspectable (no /proc field, no query syscall), so seccomp — which IS
  # reported in /proc/self/status — is the signal we read.
  #
  #   :confined    — seccomp filter active (Linux): the launcher confined us.
  #   :unconfined  — Linux, no seccomp filter: the FS wall did NOT go up (Landlock
  #                  unavailable or it failed). The entry/server tells the user.
  #   :unsupported — no /proc/self/status (non-Linux): no Linux sandbox primitives;
  #                  run without prompting, like the historical pass-through.
  module SandboxStatus
    module_function

    STATUS_PATH = "/proc/self/status"

    # /proc/self/status "Seccomp:" field — 0=disabled, 1=strict, 2=filter.
    def status
      line = File.foreach(STATUS_PATH).find { |l| l.start_with?("Seccomp:") }
      return :unsupported unless line
      line.split(":", 2).last.strip == "2" ? :confined : :unconfined
    rescue SystemCallError
      :unsupported # no /proc (non-Linux) — nothing to read
    end

    def confined?    = status == :confined
    def unconfined?  = status == :unconfined  # Linux, but the wall is not up
  end
end
