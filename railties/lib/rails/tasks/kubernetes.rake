# frozen_string_literal: true

namespace :kubernetes do
  desc "Convert docker-compose.yml to Kubernetes manifests using Kompose"
  task :convert do
    unless system("which kompose > /dev/null 2>&1")
      abort <<~MSG
        Kompose is required to convert Docker Compose files to Kubernetes manifests.

        Install Kompose:
          macOS:  brew install kompose
          Linux:  curl -L https://github.com/kubernetes/kompose/releases/latest/download/kompose-linux-amd64 -o /usr/local/bin/kompose && chmod +x /usr/local/bin/kompose
          Windows: choco install kubernetes-kompose

        See https://kompose.io/installation/ for details.
      MSG
    end

    sh "kompose convert"
  end
end
