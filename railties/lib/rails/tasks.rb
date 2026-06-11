# frozen_string_literal: true

require "rake"

# Load Rails Rakefile extensions
%w(
  container
  framework
  kubernetes
  log
  misc
  tmp
  yarn
  zeitwerk
).each do |task|
  load "rails/tasks/#{task}.rake"
end
