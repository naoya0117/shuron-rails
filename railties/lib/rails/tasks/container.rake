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
end
