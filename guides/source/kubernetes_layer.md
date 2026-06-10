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

--------------------------------------------------------------------------------

Overview
--------

When you develop with Docker and then run on Kubernetes, several Kubernetes
patterns need *application-side* support that is easy to miss during local
development (health endpoints, graceful shutdown, initialization, reading your
own pod metadata). The Kubernetes layer collects this support behind one API
(`Rails::Kubernetes`) so it is defined once and behaves correctly on each
platform.

All settings live in a single file, `config/kubernetes.rb`, which is generated
for new applications:

```ruby
# config/kubernetes.rb
Rails.application.configure do
  config.x.kubernetes = {
    liveness:  { path: "/kubernetes/health/live" },
    readiness: {
      path: "/kubernetes/health/ready",
      check_database: true,
      timeout_ms: Integer(ENV.fetch("KC_READINESS_TIMEOUT_MS", "300"))
    }
  }
end
```

NOTE: `config/kubernetes.rb` is the single configuration window. Environment
differences belong inside it (use `ENV`, as with `timeout_ms` above). Assigning
`config.x.kubernetes` somewhere else (e.g. an initializer) takes full control
and suppresses the file; the keys are plain Symbols.

Platform Detection
------------------

`Rails::Kubernetes.platform` returns one of `:kubernetes`, `:compose` or
`:local`, and is recorded in `config.x.kubernetes[:platform]` at boot:

* `:kubernetes` when `KUBERNETES_SERVICE_HOST` is present (Kubernetes injects it
  into every pod).
* otherwise `:local`.
* an explicit `KC_PLATFORM` environment variable (`kubernetes` / `compose` /
  `local`) always wins.

Features use this to switch behavior internally, so your application calls a
single API regardless of where it runs.

Health Probes
-------------

New applications expose a liveness check at `/kubernetes/health/live` and a
readiness check at `/kubernetes/health/ready`, both auto-registered as routes
(`rails_liveness_check` / `rails_readiness_check`).

* **Liveness** (`rails/health#live`) returns `200` while the process is up.
* **Readiness** (`rails/health#ready`) additionally verifies the database
  connection and returns `503` until dependencies are ready.

Configure them in `config/kubernetes.rb`:

```ruby
config.x.kubernetes = {
  liveness:  { path: "/healthz" },
  readiness: { path: "/readyz", check_database: false, timeout_ms: 500 }
}
```

* `check_database` (default `true`) — whether readiness verifies the DB.
* `timeout_ms` (default `300`) — DB check timeout.

Managed Lifecycle (Graceful Shutdown)
-------------------------------------

Register cleanup that must run when the process terminates (the end of the
lifecycle). Hooks run once, in registration order, on normal process exit —
which includes SIGTERM, the signal Kubernetes sends on pod termination:

```ruby
# e.g. config/initializers/shutdown.rb or config/kubernetes.rb
Rails::Kubernetes.on_shutdown(:drain_jobs) do
  MyWorkerPool.drain
end

Rails::Kubernetes.on_shutdown(:close_clients) do
  ExternalClient.close
end
```

A failing hook is logged and does not stop the remaining cleanup. You write the
cleanup; the layer wires it to process termination, so the same definition works
under Docker and Kubernetes.

Init Container (Initialization)
-------------------------------

Register initialization steps that must run *before* the application serves
traffic (the start of the lifecycle). They run once, in order, and fail fast (a
raising step aborts initialization), so steps should be idempotent:

```ruby
Rails::Kubernetes.init_step(:migrate) do
  ActiveRecord::Tasks::DatabaseTasks.migrate
end
```

Run them with:

```bash
$ bin/rails kubernetes:init
```

This is the difference the layer absorbs: locally the steps run as a Docker
entrypoint step, while on Kubernetes the same command runs as an
`initContainer` before the main container starts.

Self Awareness
--------------

Read the pod's own metadata, injected by the Kubernetes Downward API as
environment variables, through one accessor:

```ruby
info = Rails::Kubernetes.self_info
info.pod_name        # ENV["POD_NAME"]
info.namespace       # ENV["POD_NAMESPACE"]
info.node_name       # ENV["NODE_NAME"]
info.pod_ip          # ENV["POD_IP"]
info.service_account # ENV["POD_SERVICE_ACCOUNT"]
```

Off Kubernetes (local/Docker), where nothing is injected, every field is `nil`
— that is how the layer absorbs the difference. Use it for things like tagging
logs/metrics with the pod identity when running with multiple replicas.

NOTE: The Downward API provides declared values and identity (requests/limits,
pod name/IP/node/labels). Live resource *usage* is out of scope and comes from
elsewhere (cgroups / the metrics API).

Diagnostics
-----------

On Kubernetes, the layer warns (via the logger) when a feature is not configured
for the platform — for example, no shutdown hook registered, or the Downward API
identity not injected. This surfaces requirements that local development would
otherwise hide.

To preview what would warn before deploying, run the doctor task. Pass
`KC_PLATFORM=kubernetes` to evaluate on a Kubernetes basis from your machine:

```bash
$ KC_PLATFORM=kubernetes bin/rails kubernetes:doctor
[warn] managed_lifecycle: no graceful-shutdown hooks registered (use Rails::Kubernetes.on_shutdown)
[warn] self_awareness: Downward API identity not injected (POD_NAME/POD_NAMESPACE/NODE_NAME); check the manifest
```

Control diagnostics in `config/kubernetes.rb`:

```ruby
config.x.kubernetes = {
  diagnostics: {
    enabled: true,                 # set false to disable entirely
    ignore: [:self_awareness]      # skip specific checks by name
  }
}
```

You can register your own check from a feature or initializer:

```ruby
Rails::Kubernetes.register_check(:my_check, severity: :warn) do
  "something is misconfigured" unless my_condition_met?
end
```

The block returns a problem message (a String) when there is a problem, or `nil`
when everything is in order.
