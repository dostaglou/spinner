# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/*_test.rb"
  task.warning = true
end

Rake::TestTask.new(:soak) do |task|
  task.libs << "test"
  task.pattern = "test/soak/*_test.rb"
  task.warning = true
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: :test
