# frozen_string_literal: true

module Rails
  module Container
    # Process Containment (security): reports whether the process still carries
    # root privilege, so the container layer can surface it.
    #
    # The layer detects and surfaces; it does not enforce. Enforcement belongs
    # to the platform: the +securityContext+ generated from the
    # +process_containment+ settings (+runAsNonRoot: true+,
    # +allowPrivilegeEscalation: false+, +capabilities.drop: [ALL]+) is applied
    # by the kubelet externally and *before* the process starts, so an
    # app-layer compromise never sees root. An in-process drop would be
    # strictly weaker -- code runs as root until the drop, the drop is
    # voluntary, and changing uid mid-boot surprises everything else in the
    # process (build steps writing under Rails.root, test suites, an image that
    # already lowered only its effective ids). The layer therefore offers no
    # drop of its own.
    module Privilege
      # The id syscalls, behind a seam so tests can model "currently root"
      # without the test runner actually being root.
      class Syscalls
        def uid = Process.uid
        def euid = Process.euid
      end

      class << self
        attr_writer :syscalls

        def syscalls
          @syscalls ||= Syscalls.new
        end

        # Resets the injected syscalls (test helper).
        def reset!
          @syscalls = nil
        end

        # True while the process still carries root privilege. The effective uid
        # counts: an euid of 0 grants everything root can do even when the real
        # uid was lowered, which is how a partial in-image drop looks.
        def running_as_root?
          syscalls.uid.zero? || syscalls.euid.zero?
        end
      end
    end
  end
end
