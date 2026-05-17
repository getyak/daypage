#!/usr/bin/env ruby
# frozen_string_literal: true

# add_widget_extension.rb
#
# Creates the DayPageWidget extension target and wires it up:
#   • PBXNativeTarget of type com.apple.product-type.app-extension
#   • Sources phase with the 3 widget Swift files + StartRecordingIntent
#     (the intent file is shared with the main app via dual target membership)
#   • Build settings cloned from the main DayPage target, tuned for an
#     app-extension product (SKIP_INSTALL, bundle id, info plist path, etc.)
#   • CopyFiles "Embed Foundation Extensions" phase on the DayPage target so
#     the .appex is embedded into the .app on build
#   • Target dependency: DayPage → DayPageWidget
#
# Idempotent: re-running detects the existing target and exits.
#
# Usage:
#   ruby scripts/add_widget_extension.rb

require "xcodeproj"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)
APP_TARGET   = "DayPage"
EXT_TARGET   = "DayPageWidget"
EXT_BUNDLE   = "com.daypage.app.DayPageWidget"
WIDGET_DIR   = "DayPageWidget"

WIDGET_SOURCES = %w[
  DayPageWidgetBundle.swift
  QuickCaptureWidget.swift
  QuickCaptureControl.swift
].freeze

SHARED_INTENT_FILE = "DayPage/Intents/StartRecordingIntent.swift"

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == APP_TARGET }
raise "Main target '#{APP_TARGET}' not found" unless app_target

existing = project.targets.find { |t| t.name == EXT_TARGET }
if existing
  puts "target '#{EXT_TARGET}' already exists — nothing to do."
  exit 0
end

project_dir = File.expand_path("..", PROJECT_PATH)
widget_disk = File.join(project_dir, WIDGET_DIR)
raise "Widget folder '#{widget_disk}' missing" unless Dir.exist?(widget_disk)

# --- 1. Create the extension target -----------------------------------------

ext_target = project.new_target(
  :application,
  EXT_TARGET,
  :ios,
  "16.0",
  project.products_group,
  :swift
)
ext_target.product_type = "com.apple.product-type.app-extension"

ext_product = ext_target.product_reference
ext_product.path = "#{EXT_TARGET}.appex"
ext_product.explicit_file_type = "wrapper.app-extension"
ext_product.include_in_index = "0"

# --- 2. Tune build settings --------------------------------------------------

app_release = app_target.build_configurations.find { |c| c.name == "Release" }
inherited_signing_team = app_release&.build_settings&.dig("DEVELOPMENT_TEAM")

ext_target.build_configurations.each do |cfg|
  bs = cfg.build_settings
  bs["PRODUCT_BUNDLE_IDENTIFIER"] = EXT_BUNDLE
  bs["PRODUCT_NAME"] = "$(TARGET_NAME)"
  bs["INFOPLIST_FILE"] = "#{WIDGET_DIR}/Info.plist"
  # WidgetKit Button(intent:) + containerBackground require iOS 17. The main
  # app stays on iOS 16; users on iOS 16 simply won't see the widget.
  bs["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  bs["TARGETED_DEVICE_FAMILY"] = "1,2"
  bs["SKIP_INSTALL"] = "YES"
  bs["SWIFT_VERSION"] = "5.0"
  bs["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  bs["MARKETING_VERSION"] = "1.0"
  bs["CURRENT_PROJECT_VERSION"] = "1"
  bs["GENERATE_INFOPLIST_FILE"] = "NO"
  bs["CODE_SIGN_STYLE"] = "Automatic"
  bs["DEVELOPMENT_TEAM"] = inherited_signing_team if inherited_signing_team
  bs["LD_RUNPATH_SEARCH_PATHS"] = "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks"
  # Lets shared sources guard extension-incompatible APIs (UIApplication.shared,
  # etc.) with `#if EXTENSION`.
  bs["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "EXTENSION"
  # APPLICATION_EXTENSION_API_ONLY prevents accidental links to non-extension
  # safe APIs across the whole compilation unit.
  bs["APPLICATION_EXTENSION_API_ONLY"] = "YES"
end

# --- 3. Create the DayPageWidget PBXGroup and add Swift sources -------------

widget_group = project.main_group.find_subpath(WIDGET_DIR, true)
widget_group.set_source_tree("<group>")
widget_group.path ||= WIDGET_DIR

source_refs = WIDGET_SOURCES.map do |basename|
  abs = File.join(widget_disk, basename)
  ref = widget_group.files.find { |f| f.path == basename } || widget_group.new_file(abs)
  ref
end

info_ref = widget_group.files.find { |f| f.path == "Info.plist" } ||
           widget_group.new_file(File.join(widget_disk, "Info.plist"))
_ = info_ref

# --- 4. Add sources to the extension target ----------------------------------

ext_target.add_file_references(source_refs)

# --- 5. Dual-membership: compile StartRecordingIntent.swift in extension too -

shared_basename = File.basename(SHARED_INTENT_FILE)
intents_group = project.main_group.find_subpath("DayPage", false)&.find_subpath("Intents", false)
shared_ref = intents_group&.files&.find { |f| f.path == shared_basename }
raise "Shared intent file ref not found — run add_intents_to_target.rb first" unless shared_ref

unless ext_target.source_build_phase.files_references.include?(shared_ref)
  ext_target.add_file_references([shared_ref])
end

# --- 6. Embed the extension into the main app -------------------------------

embed_phase = app_target.copy_files_build_phases.find { |p| p.name == "Embed Foundation Extensions" }
embed_phase ||= app_target.new_copy_files_build_phase("Embed Foundation Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.dst_path = ""

unless embed_phase.files_references.include?(ext_product)
  build_file = embed_phase.add_file_reference(ext_product, true)
  build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
end

# --- 7. Target dependency ---------------------------------------------------

app_target.add_dependency(ext_target)

project.save

puts "created target '#{EXT_TARGET}' (bundle id: #{EXT_BUNDLE})"
puts "sources: #{WIDGET_SOURCES.join(', ')}"
puts "shared: #{shared_basename} (dual membership)"
puts "embedded into: #{APP_TARGET}.app/PlugIns/"
puts "done."
