# frozen_string_literal: true

require "action_controller"
require "timeout"
require "rails/kubernetes/config_loader"

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
  # Configure its path in <tt>"config/kubernetes.rb"</tt> with
  # <tt>config.x.kubernetes.liveness.path</tt> (or
  # <tt>config.x.kubernetes.endpoints.liveness_path</tt>).
  #
  # \Rails also auto-registers +rails/health#ready+ as +rails_readiness_check+.
  # Configure its path in <tt>"config/kubernetes.rb"</tt> with
  # <tt>config.x.kubernetes.readiness.path</tt> (or
  # <tt>config.x.kubernetes.endpoints.readiness_path</tt>).
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

    class << self
      def liveness_path
        liveness_config[:path].presence || "/kubernetes/health/live"
      end

      def readiness_path
        readiness_config[:path].presence || "/kubernetes/health/ready"
      end

      def liveness_config
        kubernetes_config[:liveness] || {}
      end

      def readiness_config
        kubernetes_config[:readiness] || {}
      end

      private
        # Kubernetes-layer settings as a plain Symbol-keyed Hash, loaded once by
        # Rails::Kubernetes::ConfigLoader (from config/kubernetes.rb).
        def kubernetes_config
          Rails::Kubernetes::ConfigLoader.load!
          Rails.application.config.x.kubernetes || {}
        end
    end

    def show
      render_up
    end

    def live
      head :ok
    end

    def ready
      database_status = database_check_status
      checks = { database: database_status }

      if database_status == "ok" || database_status == "skipped"
        render_ready(checks: checks)
      else
        render_not_ready(checks: checks)
      end
    rescue Exception
      render_not_ready(checks: { database: "error" })
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

      def database_check_status
        return "skipped" unless database_check_enabled?
        return "skipped" unless defined?(ActiveRecord::Base)

        Timeout.timeout(readiness_timeout_ms / 1000.0) do
          ActiveRecord::Base.connection_pool.with_connection { |conn| conn.verify!; true }
        end
        "ok"
      rescue Exception
        "error"
      end

      def database_check_enabled?
        check_database = readiness_config[:check_database]
        check_database.nil? ? true : check_database
      end

      def readiness_timeout_ms
        timeout_ms = readiness_config[:timeout_ms]
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
