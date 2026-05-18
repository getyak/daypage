#!/usr/bin/env ruby
# frozen_string_literal: true

# add_v6_missing_files.rb
#
# PR #285 (v6 Deep Experience) added 11 new Swift files to disk but never
# updated DayPage.xcodeproj/project.pbxproj. As a result, every CI build on
# main fails with "cannot find type 'DailyPageModel' in scope" etc.
#
# This script adds the missing files into their correct PBXGroup parents and
# the right target's Sources phase. Idempotent — re-running detects already
# wired-up files and exits silently for each.
#
# Usage: ruby scripts/add_v6_missing_files.rb

require "xcodeproj"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)

# {target_name => [["GroupPath/file.swift", "subpath"], ...]}
ADDS = {
  "DayPage" => [
    ["Features/Daily", "DailyPageHeader.swift"],
    ["Features/Daily", "DailyPageMetadataEditView.swift"],
    ["Features/Daily", "DailyPageModel.swift"],
    ["Features/Daily", "DailyPageParser.swift"],
    ["Features/Daily", "DailyPageSummarySection.swift"],
    ["Features/Daily", "HeroBannerView.swift"],
    ["Features/Today", "DraftStorage.swift"],
    ["Features/Today", "InputBarTutorialOverlay.swift"],
    ["Features/Today", "UndoPillView.swift"],
    ["Services",       "HapticFeedback.swift"],
  ],
  "DayPageTests" => [
    [".",              "HapticFeedbackTests.swift"],
  ]
}.freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
project_dir = File.expand_path("..", PROJECT_PATH)

def find_or_create_group(project, target_root_name, sub_path)
  root = project.main_group.find_subpath(target_root_name, false)
  raise "Top-level group '#{target_root_name}' not found" unless root
  return root if sub_path == "."
  group = root.find_subpath(sub_path, true)
  group.set_source_tree("<group>")
  group
end

ADDS.each do |target_name, entries|
  target = project.targets.find { |t| t.name == target_name }
  raise "Target '#{target_name}' not found" unless target

  entries.each do |(group_path, basename)|
    disk_dir = target_name == "DayPageTests" ? "DayPageTests" : "DayPage"
    rel = group_path == "." ? basename : File.join(group_path, basename)
    abs = File.join(project_dir, disk_dir, rel)

    unless File.exist?(abs)
      warn "skip: #{abs} not on disk"
      next
    end

    group = find_or_create_group(project, disk_dir, group_path)
    ref = group.files.find { |f| f.path == basename } || group.new_file(abs)

    if target.source_build_phase.files_references.include?(ref)
      puts "already wired: #{disk_dir}/#{rel} → #{target_name}"
    else
      target.add_file_references([ref])
      puts "added:         #{disk_dir}/#{rel} → #{target_name}"
    end
  end
end

project.save
puts "done."
