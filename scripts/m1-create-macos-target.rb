#!/usr/bin/env ruby
# frozen_string_literal: true

# m1-create-macos-target.rb
#
# Creates the DayPageMac macOS app target inside the existing DayPage.xcodeproj.
# Idempotent: re-running is a no-op if the target + product deps exist.
#
# Usage:
#   ruby scripts/m1-create-macos-target.rb

require "xcodeproj"
require "set"

PROJECT_PATH = File.expand_path("../DayPage.xcodeproj", __dir__)
TARGET_NAME  = "DayPageMac"
BUNDLE_ID    = "com.daypage.mac"
SOURCE_DIR   = "DayPageMac"
PRODUCTS     = %w[DayPageModels DayPageStorage DayPageServices].freeze
MAC_DEPLOY_TARGET = "13.0"

project = Xcodeproj::Project.open(PROJECT_PATH)

# === 1. Create target if not exists ===

existing = project.targets.find { |t| t.name == TARGET_NAME }
if existing
  puts "✓ Target #{TARGET_NAME} already exists"
  target = existing
else
  target = project.new_target(:application, TARGET_NAME, :osx, MAC_DEPLOY_TARGET)
  target.build_configurations.each do |config|
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"]            = BUNDLE_ID
    config.build_settings["MACOSX_DEPLOYMENT_TARGET"]             = MAC_DEPLOY_TARGET
    config.build_settings["SWIFT_VERSION"]                        = "5.0"
    config.build_settings["CODE_SIGN_STYLE"]                      = "Automatic"
    config.build_settings["CODE_SIGN_IDENTITY"]                   = "-"  # ad-hoc for local dev
    config.build_settings["GENERATE_INFOPLIST_FILE"]              = "YES"
    config.build_settings["INFOPLIST_KEY_LSApplicationCategoryType"] = "public.app-category.productivity"
    config.build_settings["INFOPLIST_KEY_NSPrincipalClass"]       = "NSApplication"
    config.build_settings["ENABLE_HARDENED_RUNTIME"]              = "YES"
    config.build_settings["MARKETING_VERSION"]                    = "0.1.0"
    config.build_settings["CURRENT_PROJECT_VERSION"]              = "1"
    config.build_settings["ENABLE_PREVIEWS"]                      = "YES"
    # App Sandbox off so local dev can read vault from Documents during M1.
    # M5+ migrates to user-selected paths + bookmarks for App Store eligibility.
    config.build_settings["ENABLE_APP_SANDBOX"]                   = "NO"
  end
  puts "+ Created target #{TARGET_NAME}"
end

# === 2. Add source files (recursive scan of DayPageMac/) ===

mac_group = project.main_group.find_subpath(SOURCE_DIR, true)
mac_group.set_source_tree("<group>")
mac_group.path = SOURCE_DIR

added_files = []
Dir.glob("#{File.dirname(PROJECT_PATH)}/#{SOURCE_DIR}/**/*.swift").sort.each do |abs_path|
  rel_to_mac = abs_path.sub("#{File.dirname(PROJECT_PATH)}/#{SOURCE_DIR}/", "")
  basename = File.basename(rel_to_mac)

  current_group = mac_group
  subdirs = File.dirname(rel_to_mac).split("/")
  unless subdirs == ["."]
    subdirs.each do |sub|
      child = current_group.find_subpath(sub, true)
      child.set_source_tree("<group>")
      child.path ||= sub
      current_group = child
    end
  end

  next if current_group.files.any? { |f| f.path == basename }

  file_ref = current_group.new_file(basename)
  target.source_build_phase.add_file_reference(file_ref)
  added_files << rel_to_mac
end

if added_files.empty?
  puts "✓ All source files already in target"
else
  puts "+ Added #{added_files.size} source file(s):"
  added_files.each { |f| puts "    DayPageMac/#{f}" }
end

# === 3. Link DayPageKit products ===

pkg_ref = project.root_object.package_references.find do |ref|
  ref.isa == "XCLocalSwiftPackageReference" && ref.relative_path == "DayPageKit"
end
unless pkg_ref
  warn "! Local package DayPageKit not attached — run m0-attach-daypagekit.rb first"
  exit 1
end

PRODUCTS.each do |product_name|
  existing_dep = target.package_product_dependencies.find { |d| d.product_name == product_name }
  if existing_dep
    puts "✓ #{product_name} already linked"
    next
  end

  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg_ref
  dep.product_name = product_name
  target.package_product_dependencies << dep

  frameworks_phase = target.frameworks_build_phase
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  frameworks_phase.files << build_file

  puts "+ Linked #{product_name} → #{TARGET_NAME}"
end

project.save
puts "\nSaved #{PROJECT_PATH}"
puts "\nNext:"
puts "  xcodebuild -project DayPage.xcodeproj -scheme DayPageMac -destination 'platform=macOS' build"
