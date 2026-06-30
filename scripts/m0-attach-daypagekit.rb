#!/usr/bin/env ruby
# frozen_string_literal: true

# m0-attach-daypagekit.rb
#
# Automates Step 5 of ADR-0005: attaches the local DayPageKit SwiftPM package
# (sibling directory DayPageKit/) to the DayPage Xcode project, then links the
# 3 product libraries (DayPageModels, DayPageStorage, DayPageServices) to the
# DayPage app target. Also removes the now-orphaned file references that the
# git-mv operations left behind.
#
# Idempotent: re-running is a no-op if the package + product deps are already
# wired up and the orphan refs are gone.
#
# Usage:
#   ruby scripts/m0-attach-daypagekit.rb
#
# After this script:
#   - DayPage.xcodeproj/project.pbxproj is modified in-place. Diff before
#     committing.
#   - Run: xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build
#     to verify.

require "xcodeproj"
require "set"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)
PACKAGE_REL  = "DayPageKit"                      # relative to project root
# Targets that need DayPageKit. Each maps to the list of product libs to link.
# DayPageWatch + DayPageTests may or may not exist depending on project state —
# the script tolerates missing targets.
TARGETS_AND_PRODUCTS = {
  "DayPage"        => %w[DayPageModels DayPageStorage DayPageServices],
  "DayPageWidget"  => %w[DayPageModels DayPageStorage DayPageServices],
  "DayPageTests"   => %w[DayPageModels DayPageStorage DayPageServices],
  "DayPageWatch"   => %w[DayPageModels DayPageStorage DayPageServices],
}.freeze

# Files git-mv'd to DayPageKit. Their PBXFileReference entries (relative paths
# like DayPage/Services/RawStorage.swift) are now dangling — remove them.
ORPHANED_FILES = %w[
  DayPage/Models/Memo.swift
  DayPage/Models/FrontmatterParser.swift
  DayPage/Models/CJKTextPolish.swift
  DayPage/Storage/RawStorage.swift
  DayPage/Storage/VaultInitializer.swift
  DayPage/Storage/VaultLocator.swift
  DayPage/Services/ConflictMerger.swift
  DayPage/Services/SyncQueueService.swift
  DayPage/Services/SyncQueueObserver.swift
  DayPage/Services/SyncSettings.swift
  DayPage/Services/NetworkMonitor.swift
  DayPage/Services/iCloudConflictMonitor.swift
  DayPage/Services/iCloudSyncMonitor.swift
  DayPage/Services/MemoSyncUploader.swift
  DayPage/Services/SentryReporter.swift
  DayPage/Services/DayPageLogger.swift
  DayPage/Services/KeychainHelper.swift
  DayPage/Services/HTTPClientHelper.swift
  DayPage/Services/HTTPTransport.swift
  DayPage/Services/AuthRateLimiter.swift
  DayPage/Services/CompilationService.swift
  DayPage/Services/EntityPageService.swift
  DayPage/Services/FeedbackService.swift
  DayPage/Services/GraphRetriever.swift
  DayPage/Services/LLMClient.swift
  DayPage/Services/LocationService.swift
  DayPage/Services/MemoryChatService.swift
  DayPage/Services/OnThisDayIndex.swift
  DayPage/Services/OrphanedPhotoScanner.swift
  DayPage/Services/OrphanedVoiceScanner.swift
  DayPage/Services/PassiveLocationService.swift
  DayPage/Services/RetryHelper.swift
  DayPage/Services/SampleDataSeeder.swift
  DayPage/Services/SearchService.swift
  DayPage/Services/SentryRedactor.swift
  DayPage/Services/TimelineIndex.swift
  DayPage/Services/TimelinePinService.swift
  DayPage/Services/TimelineService.swift
  DayPage/Services/VaultExportService.swift
  DayPage/Services/WeatherService.swift
  DayPage/Services/WeeklyCompilationService.swift
  DayPage/Services/WeeklyRecapService.swift
  DayPage/Utilities/DateFormatters.swift
  DayPage/Utilities/RelativeTimeFormatter.swift
  DayPage/Config/AppSettings.swift
  DayPage/Config/FeatureFlags.swift
].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)

# === 1. Attach local SwiftPM package ===

existing_local_ref = project.root_object.package_references.find do |ref|
  ref.isa == "XCLocalSwiftPackageReference" && ref.relative_path == PACKAGE_REL
end

if existing_local_ref
  puts "✓ Local package #{PACKAGE_REL} already attached"
  pkg_ref = existing_local_ref
else
  pkg_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  pkg_ref.relative_path = PACKAGE_REL
  project.root_object.package_references << pkg_ref
  puts "+ Attached local package #{PACKAGE_REL}"
end

# === 2. Link product libraries to each target that needs them ===

TARGETS_AND_PRODUCTS.each do |target_name, products|
  target = project.targets.find { |t| t.name == target_name }
  unless target
    puts "  skip: target #{target_name} not in project"
    next
  end

  products.each do |product_name|
    existing_dep = target.package_product_dependencies.find { |d| d.product_name == product_name }
    if existing_dep
      puts "✓ Product #{product_name} already linked to #{target_name}"
      next
    end

    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.package = pkg_ref
    dep.product_name = product_name
    target.package_product_dependencies << dep

    # Also add to Frameworks build phase so it actually links at build time.
    frameworks_phase = target.frameworks_build_phase
    build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = dep
    frameworks_phase.files << build_file

    puts "+ Linked #{product_name} → #{target_name}"
  end
end

# === 3. Remove orphaned file references ===
#
# Some PBXFileReference entries in this pbxproj have multi-parent inconsistencies
# (a known pre-existing condition unrelated to M0 — the file appears under both
# `App/` and `Services/` groups). The `real_path` accessor raises for these.
# Use a `basename` fallback: if the file_ref's `path` ends with one of the
# orphan basenames, treat it as a hit. This is less precise (could remove a
# same-named file in a different group) but in DayPage there are no name
# collisions among the orphan set.

orphan_basenames = ORPHANED_FILES.map { |p| File.basename(p) }.to_set
removed = []
project.files.dup.each do |file_ref|
  next unless file_ref.path
  basename = File.basename(file_ref.path)
  next unless orphan_basenames.include?(basename)

  # Confirm the file is REALLY gone from disk before removing the ref. Avoids
  # accidentally pruning a same-named file in an unrelated group.
  abs_candidate = nil
  begin
    abs_candidate = file_ref.real_path.to_s
  rescue StandardError
    # Multi-parent ref — fall back to project-root-relative `path`.
    abs_candidate = File.join(File.dirname(PROJECT_PATH), file_ref.path)
  end
  next if File.exist?(abs_candidate)

  # Also strip from any build phase referencing this file.
  project.targets.each do |t|
    t.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.dup.each do |bf|
        if bf.file_ref == file_ref
          phase.remove_build_file(bf)
        end
      end
    end
  end

  begin
    file_ref.remove_from_project
    removed << basename
  rescue StandardError => e
    warn "  ! could not remove #{basename}: #{e.message}"
  end
end

if removed.empty?
  puts "✓ No orphaned file references found"
else
  puts "- Removed #{removed.size} orphaned file ref(s):"
  removed.sort.each { |r| puts "    #{r}" }
end

project.save
puts "\nSaved #{PROJECT_PATH}"
puts "\nNext: xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build"
