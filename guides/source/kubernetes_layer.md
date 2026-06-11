**DO NOT READ THIS FILE ON GITHUB, GUIDES ARE PUBLISHED ON <https://guides.rubyonrails.org>.**

The Kubernetes Layer
====================

This guide explains the Kubernetes layer (`Rails::Kubernetes`), which aggregates
the application-side work needed to move a containerized app from local/Docker
development to a Kubernetes cluster into one place.

After reading this guide, you will know:

* How the layer is configured through `config/kubernetes.rb`.
* How the platform is detected and how the layer absorbs Docker vs Kubernetes
  differences.
* How to use Health Probes, Managed Lifecycle, Init Container and Self
  Awareness from your application.
* How diagnostics surface, at boot and via a task, anything that is not yet
  configured for Kubernetes.
* How to generate Kubernetes manifests from your Compose file.

--------------------------------------------------------------------------------

Overview
--------

When you develop with Docker and then run on Kubernetes, several Kubernetes
patterns need *application-side* support that is easy to miss during local
development (health endpoints, graceful shutdown, initialization, reading your
own pod metadata). The Kubernetes layer collects this support behind one API so
it is defined once and behaves correctly on each platform.

All settings live in a single file, `config/kubernetes.rb`, generated for new
applications:

```ruby
# config/kubernetes.rb
Rails.application.configure do
  config.x.kubernetes = {
    liveness:  { path: "/kubernetes/health/live" },
    readiness: {
      path: "/kubernetes/health/ready",
      check_database: true,
      timeout_ms: Integer(ENV.fetch("KC_READINESS_TIMEOUT_MS", "300"))
    },
    resources: {
      cpu:    { request: "100m" },
      memory: { request: "256Mi", limit: "256Mi" }
    },
    graceful_shutdown: {
      pre_stop_delay: "15s",
      grace_period:   "60s"
    }
  }
end
```

NOTE: `config/kubernetes.rb` is the single configuration window. Use `ENV` for
environment differences (as with `timeout_ms`). The keys are plain Symbols.

Platform Detection
------------------

`Rails::Kubernetes.platform` returns `:kubernetes`, `:compose` or `:local`:

* `:kubernetes` when `KUBERNETES_SERVICE_HOST` is present (Kubernetes injects it
  into every pod).
* otherwise `:local`.
* an explicit `KC_PLATFORM` of `kubernetes`, `compose` or `local` wins over the
  above; any other value is ignored and auto-detection applies.

Features use this to switch behavior internally, so your application calls a
single API regardless of where it runs.

Health Probes
-------------

New applications expose a liveness check at `/kubernetes/health/live` and a
readiness check at `/kubernetes/health/ready`, auto-registered as routes.

* **Liveness** returns `200` while the process is up.
* **Readiness** additionally verifies the database connection (configurable) and
  returns `503` until dependencies are ready.

Configure them under `liveness` / `readiness` in `config/kubernetes.rb`
(`check_database`, default `true`; `timeout_ms`, default `300`).

Managed Lifecycle (Graceful Shutdown)
-------------------------------------

Register cleanup that must run when the process terminates (the end of the
lifecycle). Hooks run once, in registration order, on normal process exit --
which includes SIGTERM, the signal Kubernetes sends on pod termination:

```ruby
# config/kubernetes.rb or an initializer
Rails::Kubernetes::GracefulShutdown.on_shutdown do
  Sidekiq.shutdown if defined?(Sidekiq)
end
```

A failing hook is logged and does not stop the remaining cleanup. The layer runs
the hooks from `at_exit`, so the same definition works under Docker and
Kubernetes and does not interfere with the app server's own shutdown. The
`graceful_shutdown` config (`pre_stop_delay`, `grace_period`) is applied to the
generated manifests (see Generating Manifests).

Init Container (Initialization)
-------------------------------

Register initialization steps that must run *before* the app serves traffic (the
start of the lifecycle). They run once, in order, and fail fast, so steps should
be idempotent:

```ruby
Rails::Kubernetes.init_step(:migrate) do
  ActiveRecord::Tasks::DatabaseTasks.migrate
end
```

`bin/rails kubernetes:init` runs the registered steps. The task is the single
place that defines them; wire it into your runtime on each platform -- as a step
in your Docker entrypoint locally/Compose, and as an `initContainer` command on
Kubernetes -- so the same steps run before the app starts everywhere. (It is not
invoked automatically by `kubernetes:convert` or the generated entrypoint.)

Self Awareness
--------------

Read the pod's own metadata, injected by the Downward API as environment
variables, through one accessor:

```ruby
info = Rails::Kubernetes.self_info
info.pod_name        # ENV["POD_NAME"]
info.namespace       # ENV["POD_NAMESPACE"]
info.node_name       # ENV["NODE_NAME"]
info.pod_ip          # ENV["POD_IP"]
info.service_account # ENV["POD_SERVICE_ACCOUNT"]
```

Off Kubernetes (local/Docker), where nothing is injected, every field is `nil`.

NOTE: The Downward API provides declared values and identity. Live resource
*usage* is out of scope (it comes from cgroups / the metrics API).

Diagnostics
-----------

On Kubernetes, the layer warns (via the logger) when a feature is not configured
for the platform -- for example, no shutdown hook registered, or the Downward
API identity not injected -- surfacing requirements local development hides.

Preview what would warn before deploying with the doctor task; pass
`KC_PLATFORM=kubernetes` to evaluate on a Kubernetes basis from your machine:

```bash
$ KC_PLATFORM=kubernetes bin/rails kubernetes:doctor
[warn] managed_lifecycle: no graceful-shutdown hooks registered (use Rails::Kubernetes::GracefulShutdown.on_shutdown)
[warn] self_awareness: Downward API identity not injected (POD_NAME/POD_NAMESPACE/NODE_NAME); check the manifest
```

Control diagnostics in `config/kubernetes.rb`:

```ruby
config.x.kubernetes = {
  diagnostics: { enabled: true, ignore: [:self_awareness] }
}
```

Register your own check from a feature or initializer:

```ruby
Rails::Kubernetes.register_check(:my_check, severity: :warn) do
  "something is misconfigured" unless my_condition_met?
end
```

The block returns a problem message when there is a problem, or `nil` otherwise.

Generating Manifests
--------------------

`bin/rails kubernetes:convert` converts your `docker-compose.yml` to Kubernetes
manifests with [Kompose](https://kompose.io), applying the health, `resources`
and `graceful_shutdown` settings from `config/kubernetes.rb` (including the
`preStop` delay and `terminationGracePeriodSeconds`). The manifests are written
to `k8s/`.
