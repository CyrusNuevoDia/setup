# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require_relative '../lib/setup_cli'

class SetupTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('setup-contract-')
    @root = File.join(@directory, 'repo')
    @home = File.join(@directory, 'home')
    FileUtils.mkdir_p(@home)
    write('config/example', "portable preference\n")
    write('config/links.json', JSON.generate(links: [{source: 'config/example', target: '.example'}]))
    write('storage/layout.json', JSON.generate(links: []))
    write('apps/manifest.json', JSON.generate(apps: [
      {id: 'editor', name: 'Editor', bundleIds: ['example.editor'], paths: ['/Applications/Example.app'], profiles: ['work'], default: true, group: 'development', install: {type: 'manual'}},
    ]))
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write(relative, content)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def cli(*arguments)
    library = File.expand_path('../lib', __dir__)
    program = 'exit Setup::CLI.run(ARGV, ' + @root.inspect + ')'
    stdout, stderr, status = Open3.capture3('/usr/bin/ruby', '-I', library, '-rsetup_cli', '-e', program, *arguments, '--home', @home, '--json')
    assert_empty stderr
    [JSON.parse(stdout), status.exitstatus]
  end

  def test_links_back_up_existing_content_and_rerun_without_another_backup
    existing = File.join(@home, '.example')
    File.write(existing, "existing user preference\n")
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    assert_equal "portable preference\n", File.read(existing)
    assert File.symlink?(existing)
    backups = Dir.glob(File.join(@home, '.setup-backups', '*', '.example'))
    assert_equal 1, backups.length
    assert_equal "existing user preference\n", File.read(backups.first)
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    assert_equal backups, Dir.glob(File.join(@home, '.setup-backups', '*', '.example'))
    result, status = cli('check', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
  end

  def test_plan_and_dry_run_do_not_create_files_or_replace_existing_preferences
    File.write(File.join(@home, '.example'), 'keep me')
    before = Dir.glob(File.join(@home, '**', '*'), File::FNM_DOTMATCH)
    result, status = cli('plan', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    result, status = cli('apply', '--profile', 'work', '--only', 'links', '--dry-run')
    assert_equal 0, status, result.inspect
    assert result['dryRun']
    assert_equal before, Dir.glob(File.join(@home, '**', '*'), File::FNM_DOTMATCH)
    assert_equal 'keep me', File.read(File.join(@home, '.example'))
  end

  def test_unknown_app_is_rejected_before_file_effects
    result, status = cli('apply', '--profile', 'work', '--only', 'links', '--with', 'dropbox')
    assert_equal 1, status
    assert_match(/Unknown apps/, result['error'])
    refute File.exist?(File.join(@home, '.example'))
  end

  def test_path_traversal_in_manifest_is_rejected_before_linking
    write('config/links.json', JSON.generate(links: [{source: 'config/example', target: '../outside'}]))
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 1, status
    assert_match(/relative path/, result['error'])
    refute File.exist?(File.join(@directory, 'outside'))
  end

  def test_storage_rejects_an_ordinary_directory_or_an_unencrypted_volume
    assert_raises(Setup::Error) { Setup::CodeVolume.validate_info!({'MountPoint' => '/Volumes/Code', 'FilesystemType' => 'apfs'}) }
    info = {'MountPoint' => '/Volumes/Code', 'VolumeName' => 'Code', 'FilesystemType' => 'apfs', 'Encryption' => false, 'Locked' => false, 'GlobalPermissionsEnabled' => true, 'Writable' => true}
    error = assert_raises(Setup::Error) { Setup::CodeVolume.validate_info!(info) }
    assert_match(/Encryption/, error.message)
    info['Encryption'] = true
    assert Setup::CodeVolume.validate_info!(info)
    info['MountPoint'] = '/Volumes/Code 1'
    assert_raises(Setup::Error) { Setup::CodeVolume.validate_info!(info) }
  end

  def test_requested_stage_order_cannot_bypass_storage_and_duplicates_are_rejected
    result, status = cli('plan', '--profile', 'work', '--only', 'apps,storage')
    assert_equal 0, status, result.inspect
    assert_equal %w[storage apps], result['stages']
    result, status = cli('plan', '--profile', 'work', '--only', 'apps,apps')
    assert_equal 1, status
    assert_match(/Duplicate stages/, result['error'])
  end

  def test_existing_links_through_a_checkout_alias_are_kept_and_check_as_current
    checkout_alias = File.join(@directory, 'checkout')
    File.symlink(@root, checkout_alias)
    target = File.join(@home, '.example')
    alias_source = File.join(checkout_alias, 'config/example')
    File.symlink(alias_source, target)
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    assert_equal alias_source, File.readlink(target)
    refute File.exist?(File.join(@home, '.setup-backups'))
    result, status = cli('check', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
  end

  def test_app_installation_refuses_a_home_without_code_foundations
    config = Setup::Config.new(@root, home: @home, profile: 'work', stages: ['apps'])
    assert_raises(Setup::Error) { Setup::Actions.new(config).apps }
    assert_empty Dir.children(@home)
  end

  def test_app_owned_settings_are_native_copies_and_runtime_changes_are_preserved
    write('config/app-settings.json', '{"portable":true}')
    write('config/links.json', JSON.generate(links: [{source: 'config/app-settings.json', target: '.codex/config.toml', mode: 'copy-if-missing'}]))
    target = File.join(@home, '.codex/config.toml')
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, 'existing runtime registration')
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 2, status, result.inspect
    assert_equal 'existing runtime registration', File.read(target)
    File.unlink(target)
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    refute File.symlink?(target)
    assert_equal '{"portable":true}', File.read(target)
    File.write(target, 'new runtime registration')
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 2, status, result.inspect
    assert_equal 'new runtime registration', File.read(target)
  end

  def test_prior_app_setting_link_is_converted_only_when_it_points_to_the_captured_source
    write('config/app-settings.json', '{"portable":true}')
    write('config/links.json', JSON.generate(links: [{source: 'config/app-settings.json', target: '.claude/settings.json', mode: 'copy-if-missing'}]))
    target = File.join(@home, '.claude/settings.json')
    FileUtils.mkdir_p(File.dirname(target))
    File.symlink(File.join(@root, 'config/app-settings.json'), target)
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 0, status, result.inspect
    refute File.symlink?(target)
    backups = Dir.glob(File.join(@home, '.setup-backups', '*', '.claude/settings.json'))
    assert_equal 1, backups.length
    assert File.symlink?(backups.first)
    File.unlink(target)
    unrelated = File.join(@directory, 'another-settings.json')
    File.write(unrelated, 'another owner')
    File.symlink(unrelated, target)
    result, status = cli('apply', '--profile', 'work', '--only', 'links')
    assert_equal 2, status, result.inspect
    assert_equal unrelated, File.readlink(target)
    assert_equal 'another owner', File.read(unrelated)
  end
end
