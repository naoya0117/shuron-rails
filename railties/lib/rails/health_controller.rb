# frozen_string_literal: true

require "action_controller"
require "timeout"
require "rails/container/config_loader"

module Rails
  # Built-in Health Check Endpoint
  #
  # \Rails also comes with a built-in health check endpoint that is reachable at
  # the +/up+ path. This endpoint will return a 200 status code if the app has
  # booted with no exceptions, and a 500 status code otherwise.
  #
  # In production, many applications are required to report their status upstream,
  # whether it's to an uptime monitor that will page an engineer when things go
  # wrong, or a load balancer or Kubernetes controller used to determine a pod's
  # health. This health check is designed to be a one-size fits all that will work
  # in many situations.
  #
  # While any newly generated \Rails applications will have the liveness health
  # check at +/up+, you can configure the path to be anything you'd like in your
  # <tt>"config/routes.rb"</tt>:
  #
  #   Rails.application.routes.draw do
  #     get "healthz" => "rails/health#show", as: :rails_health_check
  #   end
  #
  # The health check will now be accessible via the +/healthz+ path.
  #
  # \Rails also auto-registers +rails/health#live+ as +rails_liveness_check+.
  # Configure its path in <tt>"config/container.rb"</tt> with
  # <tt>config.x.container.liveness.path</tt> (or
  # <tt>config.x.container.endpoints.liveness_path</tt>).
  #
  # \Rails also auto-registers +rails/health#ready+ as +rails_readiness_check+.
  # Configure its path in <tt>"config/container.rb"</tt> with
  # <tt>config.x.container.readiness.path</tt> (or
  # <tt>config.x.container.endpoints.readiness_path</tt>).
  #
  # NOTE: This endpoint does not reflect the status of all of your application's
  # dependencies, such as the database or Redis cluster. Replace
  # <tt>"rails/health#show"</tt> with your own controller action if you have
  # application specific needs.
  #
  # Think carefully about what you want to check as it can lead to situations
  # where your application is being restarted due to a third-party service going
  # bad. Ideally, you should design your application to handle those outages
  # gracefully.
  class HealthController < ActionController::Base
    rescue_from(Exception) { render_down }

    # String values (case-insensitive) that disable a boolean setting, matching
    # ActiveModel::Type::Boolean so an ENV-sourced "0"/"off"/"false"/"FALSE"
    # turns the readiness database check off as an operator expects.
    FALSE_STRINGS = ["0", "f", "false", "off"].freeze

    class << self
      def liveness_path
        fetch_config(liveness_config, :path).presence || "/container/health/live"
      end

      def readiness_path
        fetch_config(readiness_config, :path).presence || "/container/health/ready"
      end

      def liveness_config
        fetch_config(container_config, :liveness) || {}
      end

      def readiness_config
        fetch_config(container_config, :readiness) || {}
      end

      # Reads a Symbol +key+ from the container-layer config, tolerating
      # string-keyed Hashes (as the kubernetes:convert task does) without the
      # +false || nil+ pitfall that would drop a +false+ value.
      def fetch_config(config, key)
        return unless config.respond_to?(:key?)

        if config.key?(key)
          config[key]
        elsif config.key?(key.to_s)
          config[key.to_s]
        end
      end

      private
        # Container-layer settings, loaded once by Rails::Container::ConfigLoader.
        def container_config
          Rails::Container::ConfigLoader.load!
          Rails.application.config.x.container || {}
        end
    end

    def show
      render_up
    end

    def live
      head :ok
    end

    # Readiness: the built-in database check, then every dependency the
    # application registered with Rails::Container.readiness_check.
    #
    # The whole probe shares **one** timeout budget rather than one per check.
    # Per-check timeouts multiply: with a 500ms budget and seven checks the
    # kubelet's own timeoutSeconds (3 in the generated manifest) would fire
    # first, and the developer would have to recompute it every time a
    # dependency was added. Keeping the budget for the probe is the mechanism's
    # job, not the app's.
    def ready
      checks = {}
      pending = nil

      begin
        Timeout.timeout(readiness_timeout_ms / 1000.0) do
          each_readiness_check do |name, block|
            pending = name
            checks[name] = block ? call_readiness_check(block) : database_check_status
            pending = nil
          end
        end
      rescue Timeout::Error
        # Attribute the expiry to whichever check was in flight; anything after
        # it simply never ran and is not reported as passing.
        checks[pending] = "timeout" if pending
      rescue StandardError
        checks[pending || :database] = "error"
      end

      if checks.values.all? { |v| v == "ok" || v == "skipped" }
        render_ready(checks: checks)
      else
        render_not_ready(checks: checks)
      end
    end

    private
      def render_up
        respond_to do |format|
          format.html { render html: html_status(color: "green") }
          format.json { render json: { status: "up", timestamp: Time.current.iso8601 } }
        end
      end

      def render_ready(checks:)
        respond_to do |format|
          format.html { render html: html_status(color: "green") }
          format.json { render json: { status: "ready", checks: checks, timestamp: Time.current.iso8601 } }
        end
      end

      def render_down
        respond_to do |format|
          format.html { render html: html_status(color: "red"), status: 500 }
          format.json { render json: { status: "down", timestamp: Time.current.iso8601 }, status: 500 }
        end
      end

      def render_not_ready(checks:)
        respond_to do |format|
          format.html { render html: html_status(color: "red"), status: 503 }
          format.json { render json: { status: "not_ready", checks: checks, timestamp: Time.current.iso8601 }, status: 503 }
        end
      end

      # Yields [name, block] for each check, database first. The database's
      # block is nil because it is the layer's own check, not a registered one.
      def each_readiness_check
        yield :database, nil
        return unless defined?(Rails::Container)

        Rails::Container.readiness_checks.each { |c| yield c.name, c.block }
      end

      # A check fails by raising or by returning false/nil.
      #
      # +rescue StandardError+, deliberately not +rescue Exception+. Timeout
      # unwinds the block with Timeout::ExitException, which descends from
      # Exception and *not* from StandardError, so rescuing Exception here
      # swallows the unwind and the shared budget above never fires -- a hanging
      # dependency would hang the probe rather than fail it, which is the worse
      # outcome. Measured: with +rescue Exception+ a sleeping check reported
      # "error" after running to completion instead of "timeout".
      #
      # Known limit: a check whose *own* body rescues Exception defeats the
      # budget the same way, and no framework can prevent that from outside. The
      # layer owns the budget; not sabotaging it is the block's side of the
      # contract, as idempotency is for init_step.
      def call_readiness_check(block)
        block.call ? "ok" : "error"
      rescue StandardError
        "error"
      end

      # No inner timeout: the budget is held by #ready for the whole probe.
      # StandardError for the same reason as call_readiness_check.
      def database_check_status
        return "skipped" unless database_check_enabled?
        return "skipped" unless defined?(ActiveRecord::Base)

        ActiveRecord::Base.connection_pool.with_connection { |conn| conn.verify!; true }
        "ok"
      rescue StandardError
        "error"
      end

      def database_check_enabled?
        check_database = self.class.fetch_config(readiness_config, :check_database)
        return true if check_database.nil?
        return !FALSE_STRINGS.include?(check_database.strip.downcase) if check_database.is_a?(String)

        check_database
      end

      def readiness_timeout_ms
        timeout_ms = self.class.fetch_config(readiness_config, :timeout_ms)
        timeout_ms.present? ? timeout_ms.to_i : 300
      end

      def readiness_config
        self.class.readiness_config
      end

      def html_status(color:)
        %(<!DOCTYPE html><html><body style="background-color: #{color}"></body></html>).html_safe
      end
  end
end
