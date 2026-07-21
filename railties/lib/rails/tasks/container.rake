# frozen_string_literal: true

namespace :container do
  desc "Run registered container-layer initialization steps (Init Container)"
  task init: :environment do
    require "rails/container"
    Rails::Container.run_init!
  end

  desc "Report container-layer diagnostics (use CONTAINER_PLATFORM=kubernetes to preflight)"
  task doctor: :environment do
    require "rails/container"
    diagnostics = Rails::Container.diagnostics

    if diagnostics.empty?
      puts "[container] no diagnostics."
    else
      diagnostics.each do |d|
        puts "[#{d[:severity]}] #{d[:name]}: #{d[:message]}"
      end
    end
  end

  desc "Report the container-layer conformance matrix (Layer 1; CONTAINER_PLATFORM=kubernetes to preflight)"
  task conformance: :environment do
    require "rails/container/conformance"

    results = Rails::Container::Conformance.run
    label = { pass: "PASS", fail: "FAIL", na: "N/A ", skip: "SKIP" }
    width = results.map { |r| r.pattern.length }.max

    puts "[container] conformance (platform=#{Rails::Container.platform})"
    results.each do |r|
      puts "  [#{label[r.status] || r.status}] #{r.pattern.ljust(width)}  #{r.detail}"
    end

    failed = results.select { |r| r.status == :fail }
    abort "[container] conformance FAILED: #{failed.map(&:pattern).join(', ')}" unless failed.empty?
  end
end
