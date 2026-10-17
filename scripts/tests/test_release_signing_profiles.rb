#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Isolated host regression for the TestFlight release signing/export assembly.
#
# The regression loads a COPY of the shipped fastlane/Fastfile into a synthetic
# temporary directory (it never loads the repository root .env), captures the
# lane DSL blocks, and executes the real beta/release match ->
# configure_release_signing -> build_app export-option paths against recorded
# no-op doubles.
#
# Boundary policy: the harness deliberately refuses subprocess shell execution
# (sh raises RefusedOperation) and performs no keychain, xcodebuild, App Store
# Connect, match git/remote, or upload side effect. Every external fastlane
# operation is recorded as a call and does nothing else. The increment/version
# and config-setup lanes are boundary stubs because they are unrelated to the
# signing/export assembly under test.
#
# Requires only system Ruby with the bundled minitest. No Fastlane gem, no
# bundler/npm/pnpm installation, no repository .env or credentials, no network,
# no simulator or xcodebuild.
#
# Run: ruby scripts/tests/test_release_signing_profiles.rb
# (set TMPDIR to pin the synthetic fixture directory)

require "fileutils"
require "minitest/autorun"
require "tmpdir"

# Raised for any operation the regression harness must never perform.
class RefusedOperation < StandardError; end

# Raised by the UI double in place of fastlane's UI.user_error!.
class UserError < StandardError; end

# One recorded external fastlane operation: the action name and its params.
Call = Struct.new(:action, :params)

# Synthetic stand-ins for the constants the Fastfile references. Actions
# behaves like fastlane's Actions.lane_context (a per-run hash keyed by the
# SharedValues constants); UI converts user_error! into a catchable error.
module SharedValues
  MATCH_PROVISIONING_PROFILE_MAPPING = :match_provisioning_profile_mapping
end

module Actions
  class << self
    def lane_context
      @lane_context ||= {}
    end

    def reset_lane_context
      @lane_context = {}
    end
  end
end

module UI
  class << self
    def message(_text); end

    def success(_text); end

    def error(_text); end

    def user_error!(text)
      raise UserError, text
    end
  end
end

# Executes a copy of the shipped Fastfile against recorded no-op doubles.
class FastfileHarness
  attr_reader :calls, :evaluated_path, :lane_names

  # Names match real match's profile naming, e.g. "match AppStore com.daypage.app.share".
  def self.generated_profile_name(identifier)
    "match AppStore #{identifier}"
  end

  def initialize(shipped_fastfile, isolate_root, options = {})
    @stub_lanes = Array(options.fetch(:stub_lanes,
                                      %w[setup_secrets validate_release_supabase_config
                                         increment_build])).map(&:to_s)
    @match_omits = Array(options.fetch(:match_omits, [])).map(&:to_s)
    @lanes = {}
    @lane_names = []
    @calls = []
    Actions.reset_lane_context
    fastlane_dir = File.join(isolate_root, "fastlane")
    FileUtils.mkdir_p(fastlane_dir)
    @evaluated_path = File.join(fastlane_dir, "Fastfile")
    FileUtils.cp(shipped_fastfile, @evaluated_path)
    instance_eval(File.read(@evaluated_path, encoding: "UTF-8"), @evaluated_path, 1)
  end

  # Executes one lane top-to-bottom and returns the recorded call log.
  def execute(lane_name)
    @calls = []
    Actions.reset_lane_context
    run_lane(lane_name.to_s)
    @calls
  end

  # ── Fastfile DSL capture ────────────────────────────────────────────────
  def default_platform(*_args); end

  def desc(_text); end

  def platform(_name, &block)
    instance_eval(&block)
  end

  def lane(name, &block)
    register_lane(name, block)
  end

  def private_lane(name, &block)
    register_lane(name, block)
  end

  def error(*_args, &_block); end

  # ── External fastlane operations: recorded no-op doubles ────────────────
  # match also populates the lane-context profile mapping exactly like the
  # real action does, so the lane's real lookup/assembly code runs unchanged.
  def match(params = {})
    record(:match, params)
    identifier = params[:app_identifier].to_s
    return if @match_omits.include?(identifier)

    mapping = (Actions.lane_context[SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING] ||= {})
    mapping[identifier] = self.class.generated_profile_name(identifier)
  end

  def create_keychain(params = {})
    record(:create_keychain, params)
  end

  def update_code_signing_settings(params = {})
    record(:update_code_signing_settings, params)
  end

  def build_app(params = {})
    record(:build_app, params)
  end

  def upload_to_testflight(params = {})
    record(:upload_to_testflight, params)
  end

  def upload_to_app_store(params = {})
    record(:upload_to_app_store, params)
  end

  def app_store_connect_api_key(params = {})
    record(:app_store_connect_api_key, params)
    :synthetic_api_key
  end

  def changelog_from_git_commits(params = {})
    record(:changelog_from_git_commits, params)
    "synthetic changelog"
  end

  # No subprocess may ever run from this harness.
  def sh(*_args)
    raise RefusedOperation, "shell execution is refused by the regression harness"
  end

  private

  def register_lane(name, block)
    key = name.to_s
    @lanes[key] = block
    @lane_names << key
    define_singleton_method(name) do |*_args, &_ignored|
      run_lane(key)
    end
  end

  def run_lane(name)
    if @stub_lanes.include?(name)
      record(:lane_stub, lane: name)
      return nil
    end
    block = @lanes.fetch(name) { raise NameError, "lane #{name} is not defined in the Fastfile" }
    instance_exec(&block)
  end

  def record(action, params)
    @calls << Call.new(action, params)
  end
end

# Behavior regressions for the beta/release signing and export assembly.
class TestReleaseSigningProfiles < Minitest::Test
  SHIPPED_FASTFILE = File.expand_path("../../fastlane/Fastfile", __dir__).freeze
  TARGETS = {
    "DayPage"       => "com.daypage.app",
    "DayPageWidget" => "com.daypage.app.DayPageWidget",
    "DayPageWatch"  => "com.daypage.app.watchkitapp",
    "DayPageShare"  => "com.daypage.app.share"
  }.freeze
  ALL_IDENTIFIERS = TARGETS.values.freeze
  LANES = %w[beta release].freeze

  def setup
    @saved_env = ENV.to_h
    ENV["DEVELOPMENT_TEAM"] = "SYNTHETIC01"
    %w[APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_ISSUER_ID
       APP_STORE_CONNECT_API_KEY_CONTENT MATCH_GIT_URL MATCH_PASSWORD
       MATCH_KEYCHAIN_PASSWORD RELEASE_VERSION].each { |key| ENV.delete(key) }
    @isolate = Dir.mktmpdir("daypage-release-signing-")
  end

  def teardown
    FileUtils.remove_entry(@isolate) if @isolate && File.directory?(@isolate)
    ENV.replace(@saved_env)
  end

  # ── Per-lane behavior (both beta and release) ───────────────────────────
  LANES.each do |lane_name|
    define_method("test_#{lane_name}_match_requests_all_four_exact_identifiers") do
      calls = harness.execute(lane_name)
      match_calls = calls.select { |call| call.action == :match }
      assert_equal 4, match_calls.size, "expected exactly four match calls"
      assert_equal ALL_IDENTIFIERS.sort,
                   match_calls.map { |call| call.params[:app_identifier] }.sort
      match_calls.each do |call|
        assert_equal "appstore", call.params[:type],
                     "match for #{call.params[:app_identifier]} must be an App Store profile fetch"
      end
    end

    define_method("test_#{lane_name}_signs_each_release_target_with_its_generated_profile") do
      calls = harness.execute(lane_name)
      signing_calls = calls.select { |call| call.action == :update_code_signing_settings }
      assert_equal TARGETS.size, signing_calls.size,
                   "expected one Release signing configuration per target"
      assert_equal TARGETS.keys.sort,
                   signing_calls.map { |call| Array(call.params[:targets]).first }.sort
      signing_calls.each do |call|
        target = Array(call.params[:targets]).first
        identifier = TARGETS.fetch(target)
        assert_equal false, call.params[:use_automatic_signing],
                     "#{target} must use manual signing"
        assert_equal "Apple Distribution", call.params[:code_sign_identity]
        assert_equal ["Release"], call.params[:build_configurations]
        assert_equal "DayPage.xcodeproj", call.params[:path]
        assert_equal ENV["DEVELOPMENT_TEAM"], call.params[:team_id]
        assert_equal self.class.generated(identifier), call.params[:profile_name],
                     "#{target} must receive the profile match generated for #{identifier}"
      end
    end

    define_method("test_#{lane_name}_export_provisioning_profiles_exactly_match_all_four") do
      calls = harness.execute(lane_name)
      build_calls = calls.select { |call| call.action == :build_app }
      assert_equal 1, build_calls.size, "expected exactly one archive/export build_app"
      export_options = build_calls.first.params[:export_options]
      expected = {}
      ALL_IDENTIFIERS.each { |identifier| expected[identifier] = self.class.generated(identifier) }
      assert_equal expected, export_options[:provisioningProfiles]
      assert_equal "manual", export_options[:signingStyle]
      assert_equal "app-store", export_options[:method]
    end

    define_method("test_#{lane_name}_missing_share_mapping_fails_before_archive_or_upload") do
      h = harness(match_omits: ["com.daypage.app.share"])
      error = assert_raises(UserError) { h.execute(lane_name) }
      assert_includes error.message, "com.daypage.app.share",
                      "the failure must name the missing Share identifier"
      actions = h.calls.map(&:action)
      assert_empty actions.select { |action| action == :build_app },
                   "no archive/export may run with a missing Share mapping"
      assert_empty actions.select { |action| %i[upload_to_testflight upload_to_app_store].include?(action) },
                   "no upload may run with a missing Share mapping"
    end

    define_method("test_#{lane_name}_preserves_release_upload_behavior") do
      calls = harness.execute(lane_name)
      if lane_name == "beta"
        uploads = calls.select { |call| call.action == :upload_to_testflight }
        assert_equal 1, uploads.size
        assert_equal true, uploads.first.params[:skip_waiting_for_build_processing]
        assert_empty calls.select { |call| call.action == :upload_to_app_store }
      else
        uploads = calls.select { |call| call.action == :upload_to_app_store }
        assert_equal 1, uploads.size
        assert_equal true, uploads.first.params[:submit_for_review]
        assert_equal false, uploads.first.params[:automatic_release]
        assert_empty calls.select { |call| call.action == :upload_to_testflight }
      end
    end
  end

  # ── Isolation and boundary policy ───────────────────────────────────────
  def test_isolated_copy_loads_without_touching_repository_env
    env_before = ENV.to_h
    h = harness
    h.execute("beta")
    h.execute("release")
    assert env_before == ENV.to_h,
           "loading and running the Fastfile copy must not read any .env"
    assert_equal File.join(@isolate, "fastlane", "Fastfile"), h.evaluated_path
    assert_equal File.read(SHIPPED_FASTFILE), File.read(h.evaluated_path),
                 "the evaluated file must be a byte-identical copy of the shipped Fastfile"
  end

  def test_harness_refuses_shell_subprocess_execution
    h = harness
    assert_raises(RefusedOperation) { h.sh("xcodebuild", "-version") }
    assert_raises(RefusedOperation) { h.sh("git", "push") }
  end

  # Profile name match generates for an identifier (see FastfileHarness#match).
  def self.generated(identifier)
    FastfileHarness.generated_profile_name(identifier)
  end

  private

  def harness(options = {})
    FastfileHarness.new(SHIPPED_FASTFILE, @isolate, options)
  end
end
