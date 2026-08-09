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
        def seteuid(uid) = Process::Sys.seteuid(uid)
        def setegid(gid) = Process::Sys.setegid(gid)
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

        # The passwd entry for a user name or numeric uid. Exposed so callers can
        # resolve the target once and reuse its uid/gid (e.g. to hand files over
        # before dropping).
        def passwd_for(user)
          resolve_user(user)
        end

        # Permanently drops to +user+ (and +group+, defaulting to the user's
        # primary group). Resolution happens first so a bad user/group fails
        # fast even during local development. Supplementary groups and the gid
        # are set before the uid, because dropping the uid first would forfeit
        # the privilege needed to change the others. Returns a DropResult;
        # raises DropError if the drop did not verifiably take effect.
        def drop_to(user:, group: nil)
          pwent = resolve_user(user)
          user = pwent.name
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

          # An app that already lowered only its *effective* ids (a partial drop
          # via seteuid, as some images do in their own boot code) leaves the
          # process real-root but without the effective privilege initgroups
          # needs -- the drop would fail with EPERM. Restoring the effective ids
          # from the real ones is permitted precisely because the real uid is
          # still 0, so reclaim them and proceed to drop everything for good.
          reclaim_effective_privilege if syscalls.uid.zero? && !syscalls.euid.zero?

          syscalls.initgroups(user, target_gid)
          syscalls.setgid(target_gid)
          syscalls.setuid(target_uid)
          verify!(target_uid, target_gid)

          DropResult.new(status: :dropped, uid: target_uid, gid: target_gid)
        end

        private
          # Raises the effective ids back to the real (root) ones so the drop can
          # run. Only reachable while the real uid is 0.
          def reclaim_effective_privilege
            syscalls.setegid(syscalls.gid)
            syscalls.seteuid(syscalls.uid)
          end

          # Accepts a user name or a numeric uid. A uid is resolved back to its
          # passwd entry because +initgroups+ needs the user's *name*, and the
          # entry also supplies the primary gid when no group was given.
          def resolve_user(user)
            case user
            when Integer then Etc.getpwuid(user)
            else Etc.getpwnam(user.to_s)
            end
          end

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
