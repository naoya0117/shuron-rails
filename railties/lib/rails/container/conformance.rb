# frozen_string_literal: true

require "rack/mock"
require "rails/container"
require "rails/health_controller"

module Rails
  module Container
    # = \Rails \Container Conformance (Layer 1 verification)
    #
    # Introspects a booted application and reports, per Kubernetes pattern
    # aggregated in the container layer, whether the pattern is wired up and
    # behaving. Produces a pattern-by-status matrix that is *reusable across any
    # application* the container layer is applied to -- the uniform container-
    # layer API is what makes uniform verification possible.
    #
    # Statuses:
    # - +:pass+  verified (mechanism present and behaving)
    # - +:fail+  wired but wrong, or a required posture not met
    # - +:na+    nothing registered -- the app does not use this pattern
    # - +:skip+  needs a live cluster; deferred to Layer 3 (E2E)
    #
    # Behavioral checks that require a real orchestrator (readiness gating a
    # Service, a real SIGTERM drain, migration idempotency against a live DB)
    # are out of scope here and belong to Layer 3. They stay out of scope
    # deliberately: this runs in its own short-lived process, so it can only
    # ever inspect a registry, never watch the server that will handle the
    # signal. What the server actually did is recorded by
    # Rails::Container::Events and asserted from outside the process --
    # verification/verify.sh.
    module Conformance
      Result = Struct.new(:pattern, :status, :detail, keyword_init: true)

      class << self
        # Runs every check and returns an Array of Result. When +platform+ is
        # given (e.g. +:kubernetes+) the platform-conditional checks are
        # evaluated as if running on that platform -- the "preflight" mode,
        # matching how +container:doctor+ is run with +CONTAINER_PLATFORM+.
        def run(app: Rails.application, platform: nil)
          with_platform(platform) do
            [
              health_probe(app),
              managed_lifecycle,
              init_container,
              self_awareness,
              process_containment,
              diagnostics_check,
            ]
          end
        end

        private
          # Health Probe: the liveness/readiness endpoints must be mounted and
          # answer in-process. Liveness must be 200; readiness answering with a
          # health status (200 ready / 503 not-ready) proves the endpoint works.
          def health_probe(app)
            live = request_status(app, HealthController.liveness_path)
            ready = request_status(app, HealthController.readiness_path)

            if live.nil?
              Result.new(pattern: "Health Probe", status: :skip,
                detail: "could not issue in-process request (no rack app)")
            elsif live == 200 && [200, 503].include?(ready)
              Result.new(pattern: "Health Probe", status: :pass,
                detail: "liveness #{live}, readiness #{ready} (#{ready == 200 ? 'ready' : 'not_ready'})")
            else
              Result.new(pattern: "Health Probe", status: :fail,
                detail: "liveness #{live.inspect}, readiness #{ready.inspect} -- are the health routes mounted?")
            end
          end

          # Managed Lifecycle: at least one graceful-shutdown hook registered.
          def managed_lifecycle
            hooks = GracefulShutdown.hooks.size
            timing = Container.config[:graceful_shutdown]
            if hooks.positive?
              Result.new(pattern: "Managed Lifecycle", status: :pass,
                detail: "#{hooks} shutdown hook(s) registered" \
                  "#{timing ? "; timing #{timing.inspect}" : ''} (real SIGTERM drain: verification/verify.sh)")
            else
              Result.new(pattern: "Managed Lifecycle", status: :na,
                detail: "no on_shutdown hooks registered")
            end
          end

          # Init Container: initialization steps declared (idempotency against a
          # live DB is verified at Layer 3).
          def init_container
            steps = Container.init_steps.map(&:name)
            if steps.any?
              Result.new(pattern: "Init Container", status: :pass,
                detail: "steps: #{steps.join(', ')} (actual run: verification/verify.sh)")
            else
              Result.new(pattern: "Init Container", status: :na, detail: "no init steps registered")
            end
          end

          # Self Awareness: on Kubernetes the Downward API identity must be read;
          # off Kubernetes every field must be nil (the platform difference is
          # absorbed and local env is not surfaced).
          def self_awareness
            info = Container.self_info
            if Container.platform == :kubernetes
              if info.pod_name
                Result.new(pattern: "Self Awareness", status: :pass,
                  detail: "Downward API read: pod=#{info.pod_name} ns=#{info.namespace} node=#{info.node_name}")
              else
                Result.new(pattern: "Self Awareness", status: :fail,
                  detail: "on kubernetes but POD_* not injected -- check the manifest Downward API")
              end
            elsif info.to_h.values.all?(&:nil?)
              Result.new(pattern: "Self Awareness", status: :pass,
                detail: "off kubernetes: self_info nil (difference absorbed); run platform: :kubernetes to exercise injection")
            else
              Result.new(pattern: "Self Awareness", status: :fail,
                detail: "off kubernetes but self_info leaked values: #{info.to_h.compact.inspect}")
            end
          end

          # Process Containment: the non-root requirement. Non-root passes; root
          # fails here and the doctor warns about it on every platform. Both read
          # privilege through Privilege.running_as_root?, so an image that lowered
          # only its effective uid is judged the same way in either place.
          def process_containment
            configured = !Container.config[:process_containment].nil?
            if Privilege.running_as_root?
              Result.new(pattern: "Process Containment", status: :fail,
                detail: "running as root (uid #{Privilege.syscalls.uid}/euid #{Privilege.syscalls.euid})" \
                  "#{configured ? '' : '; no process_containment config'} -- " \
                  "enforce non-root via the generated securityContext")
            else
              Result.new(pattern: "Process Containment", status: :pass,
                detail: "running as non-root (uid #{Privilege.syscalls.uid})" \
                  "#{configured ? '; process_containment declared' : ''}")
            end
          end

          # Diagnostics: the surfacing mechanism itself. Reports pending problems
          # (this wraps container:doctor).
          def diagnostics_check
            problems = Container.diagnostics
            detail = if problems.empty?
              "no pending diagnostics"
            else
              problems.map { |d| "#{d[:name]}(#{d[:severity]})" }.join(", ")
            end
            Result.new(pattern: "Diagnostics", status: :pass, detail: "#{problems.size} pending: #{detail}")
          end

          # Issues an in-process request. Presents a permitted Host and an https
          # scheme so a real app's host authorization and force_ssl redirect do
          # not turn a healthy endpoint into a 403/301 (the probe verifies the
          # health action, not those middlewares).
          def request_status(app, path)
            return nil unless app

            env = ::Rack::MockRequest.env_for(path,
              "HTTP_HOST" => permitted_host,
              "HTTPS" => "on",
              "rack.url_scheme" => "https")
            status, = app.call(env)
            status
          rescue StandardError
            nil
          end

          # The first concrete allowed host (config.hosts holds Strings, Regexps
          # and IPAddrs; a leading "." marks a subdomain wildcard). Falls back to
          # localhost when hosts is unrestricted or unavailable.
          def permitted_host
            hosts = begin
              Rails.application.config.hosts
            rescue StandardError
              nil
            end
            Array(hosts).find { |h| h.is_a?(String) && !h.empty? && !h.start_with?(".") } || "localhost"
          end

          def with_platform(platform)
            return yield unless platform

            saved = ENV["CONTAINER_PLATFORM"]
            ENV["CONTAINER_PLATFORM"] = platform.to_s
            begin
              yield
            ensure
              saved.nil? ? ENV.delete("CONTAINER_PLATFORM") : (ENV["CONTAINER_PLATFORM"] = saved)
            end
          end
      end
    end
  end
end
