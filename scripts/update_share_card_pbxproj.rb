#!/usr/bin/env ruby
# frozen_string_literal: true

# update_share_card_pbxproj.rb
#
# Issue #302 — Share-card system.
# Adds new ShareCard source files to DayPage.xcodeproj and removes the deleted
# DailySharePosterView.swift reference. Idempotent — re-running is safe.
#
# Usage: ruby scripts/update_share_card_pbxproj.rb

require "xcodeproj"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)
project_dir = File.expand_path("..", PROJECT_PATH)

TARGET_NAME = "DayPage"
target = project.targets.find { |t| t.name == TARGET_NAME }
raise "Target '#{TARGET_NAME}' not found" unless target

# ── Removals ──
REMOVALS = [
  "Features/Shared/DailySharePosterView.swift"
].freeze

REMOVALS.each do |rel|
  basename = File.basename(rel)
  removed = false
  project.files.dup.each do |f|
    next unless f.path == basename || (f.real_path && f.real_path.to_s.end_with?(rel))
    target.source_build_phase.files.dup.each do |bf|
      if bf.file_ref == f
        target.source_build_phase.remove_build_file(bf)
        removed = true
      end
    end
    f.remove_from_project
    removed = true
  end
  puts(removed ? "removed:       DayPage/#{rel}" : "skip remove:   DayPage/#{rel} (not in project)")
end

# ── Additions ──
ADDS = [
  ["Features/Shared/ShareCard", "ShareCardSystem.swift"]
].freeze

def find_or_create_group(project, root_name, sub_path)
  root = project.main_group.find_subpath(root_name, false)
  raise "Top-level group '#{root_name}' not found" unless root
  return root if sub_path == "."
  group = root.find_subpath(sub_path, true)
  group.set_source_tree("<group>")
  group
end

ADDS.each do |(group_path, basename)|
  abs = File.join(project_dir, "DayPage", group_path, basename)

  unless File.exist?(abs)
    warn "skip add:      #{abs} not on disk"
    next
  end

  group = find_or_create_group(project, "DayPage", group_path)
  ref = group.files.find { |f| f.path == basename } || group.new_file(abs)

  if target.source_build_phase.files_references.include?(ref)
    puts "already wired: DayPage/#{group_path}/#{basename}"
  else
    target.add_file_references([ref])
    puts "added:         DayPage/#{group_path}/#{basename} -> #{TARGET_NAME}"
  end
end

project.save
puts "done."
