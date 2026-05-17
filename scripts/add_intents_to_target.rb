#!/usr/bin/env ruby
# frozen_string_literal: true

# add_intents_to_target.rb
#
# Adds the new App Intents source files (Intents/StartRecordingIntent.swift,
# Intents/DayPageShortcuts.swift) into the DayPage Xcode target.
#
# Idempotent: re-running is a no-op if the files are already wired up.
#
# Usage:
#   ruby scripts/add_intents_to_target.rb

require "xcodeproj"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)
TARGET_NAME  = "DayPage"
GROUP_NAME   = "Intents"
FILE_PATHS   = %w[
  DayPage/Intents/StartRecordingIntent.swift
  DayPage/Intents/DayPageShortcuts.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
target  = project.targets.find { |t| t.name == TARGET_NAME }
raise "Target #{TARGET_NAME} not found" unless target

# Resolve / create the "Intents" group under the top-level DayPage group.
daypage_group = project.main_group.find_subpath("DayPage", false)
raise "Top-level DayPage group not found" unless daypage_group
intents_group = daypage_group.find_subpath(GROUP_NAME, true)
intents_group.set_source_tree("<group>")
intents_group.path ||= "Intents"

added = []
skipped = []

FILE_PATHS.each do |rel_path|
  basename = File.basename(rel_path)
  abs_path = File.expand_path("../#{rel_path}", __dir__)

  existing_ref = intents_group.files.find { |f| f.path == basename || f.path == rel_path }
  file_ref = existing_ref || intents_group.new_file(abs_path)

  already_built = target.source_build_phase.files_references.include?(file_ref)
  if already_built
    skipped << basename
  else
    target.add_file_references([file_ref])
    added << basename
  end
end

project.save

puts "added: #{added.join(', ')}" unless added.empty?
puts "already wired: #{skipped.join(', ')}" unless skipped.empty?
puts "done."
