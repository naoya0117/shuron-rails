# frozen_string_literal: true

require "etc"

module Rails
  module Container
    # Process Containment (security): permanently drops the running process to
    # an unprivileged user/group at runtime.
    #
    # This is defense-in-depth, *not* a substitute for the platform's own
    # controls. In Kubernetes, prefer never running as root at all via
    # +securityContext+ (+runAsNonRoot: true+, +allowPrivilegeEscalation:
    # false+, +capabilities.drop: [ALL]+): the kubelet enforces those
    # externally and before the process starts, so an app-layer compromise
    # never sees root. An in-process drop is weaker -- code runs as root until
    # the drop, and the drop is voluntary -- so use +drop_to+ only for the
    # residual case where the process must start as root (e.g. to bind a
    # privileged port or read a root-owned file) and that work cannot move to
    # an Init Container. Linux capabilities and +no_new_privs+ are left to
    # +securityContext+, which handles them declaratively and non-bypassably.
    module Privilege
      # Raised when a drop was attempted but the process did not end up at the
      # target uid/gid. We fail closed rather than continue with elevated
      # privileges the caller believed were gone.
      class DropError < StandardError; end

      # Outcome of a drop_to call: +status+ is +:dropped+ when ids changed,
      # +:noop+ when the process was already unprivileged.
      DropResult = Struct.new(:status, :uid, :gid, keyword_init: true)

      # The OS syscalls, behind a seam so they can be substituted in tests.
      class Syscalls
        def uid = Process.uid
        def euid = Process.euid
        def gid = Process.gid
        def egid = Process.egid
        def initgroups(user, gid) = Process.initgroups(user, gid)
        def setgid(gid) = Process::Sys.setgid(gid)
        def setuid(uid) = Process::Sys.setuid(uid)
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

        # Permanently drops to +user+ (and +group+, defaulting to the user's
        # primary group). Resolution happens first so a bad user/group fails
        # fast even during local development. Supplementary groups and the gid
        # are set before the uid, because dropping the uid first would forfeit
        # the privilege needed to change the others. Returns a DropResult;
        # raises DropError if the drop did not verifiably take effect.
        def drop_to(user:, group: nil)
          user = user.to_s
          pwent = Etc.getpwnam(user)
          target_uid = pwent.uid
          target_gid = group ? resolve_gid(group) : pwent.gid

          # Dropping "to" root is a contradiction: the drop would verify happily
          # while leaving the process at uid/gid 0, defeating the whole purpose.
          # Reject it before touching any syscall.
          if target_uid.zero? || target_gid.zero?
            raise ArgumentError, "refusing to drop to a privileged target " \
              "(uid=#{target_uid}, gid=#{target_gid}); drop_to expects an unprivileged user/group"
          end

          # Already unprivileged: the goal (not running as root) holds, and we
          # would lack the privilege to change ids anyway. Both the real and the
          # effective uid must be non-root -- an effective uid of 0 still carries
          # full privilege, so that case is a real drop, not a noop.
          unless syscalls.uid.zero? || syscalls.euid.zero?
            return DropResult.new(status: :noop, uid: syscalls.uid, gid: syscalls.gid)
          end

          syscalls.initgroups(user, target_gid)
          syscalls.setgid(target_gid)
          syscalls.setuid(target_uid)
          verify!(target_uid, target_gid)

          DropResult.new(status: :dropped, uid: target_uid, gid: target_gid)
        end

        private
          def resolve_gid(group)
            return group if group.is_a?(Integer)

            Etc.getgrnam(group.to_s).gid
          end

          # Confirms real *and* effective ids both moved, so the privilege is
          # genuinely gone (not merely the effective uid).
          def verify!(uid, gid)
            return if syscalls.uid == uid && syscalls.euid == uid &&
                      syscalls.gid == gid && syscalls.egid == gid

            raise DropError, "privilege drop did not take effect " \
              "(uid=#{syscalls.uid}/#{syscalls.euid}, gid=#{syscalls.gid}/#{syscalls.egid}; " \
              "wanted uid=#{uid}, gid=#{gid})"
          end
      end
    end
  end
end
