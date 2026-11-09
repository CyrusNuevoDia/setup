# frozen_string_literal: true

require "open3"
require "fileutils"

module Setup
  module CodeVolume
    PATH = "/Volumes/Code"

    def self.info
      plist, error, status = Open3.capture3('/usr/sbin/diskutil', 'info', '-plist', PATH)
      raise Error, "Code is not mounted; create or unlock it using storage/README.md (#{error.strip})" unless status.success?
      json, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', '-', stdin_data: plist)
      raise Error, "Cannot read Code volume metadata: #{error.strip}" unless status.success?
      JSON.parse(json)
    end

    def self.validate_info!(data)
      required = {
        'MountPoint' => PATH, 'VolumeName' => 'Code', 'FilesystemType' => 'apfs',
        'Encryption' => true, 'Locked' => false, 'GlobalPermissionsEnabled' => true,
        'Writable' => true
      }
      failed = required.keys.reject { |key| data[key] == required[key] }
      raise Error, "Code must be a mounted, unlocked, encrypted, ownership-enabled writable APFS volume; failed: #{failed.join(', ')}" unless failed.empty?
      true
    end

    def self.validate!
      raise Error, "Code mount path is a symlink" if File.symlink?(PATH)
      validate_info!(info)
      true
    end

    def self.alias_state(source, destination)
      if File.symlink?(source)
        return 'ok' if Setup.linked_to?(source, destination) && File.directory?(destination)
        return 'conflict'
      end
      return 'missing' unless File.exist?(source)
      return 'empty' if File.directory?(source) && Dir.empty?(source)
      'migration_required'
    end

    def self.require_foundations!(config)
      validate!
      foundational = config.storage_links.select { |entry| %w[.local .cache].include?(entry['source']) }
      unless foundational.length == 2 && foundational.all? { |entry| alias_state(config.home_path(entry['source']), File.join(PATH, entry['destination'])) == 'ok' }
        raise Error, 'Establish the .local and .cache aliases with the storage stage before installing tools or apps'
      end
    end

    def self.apply_links(config)
      validate!
      conflicts = config.storage_links.each_with_object([]) do |link, result|
        source = config.home_path(link['source'])
        state = alias_state(source, File.join(PATH, link['destination']))
        result << {source: source, state: state} if %w[conflict migration_required].include?(state)
      end
      unless conflicts.empty?
        raise Error, "Existing developer data needs a reviewed migration; no storage aliases changed: #{conflicts.map { |item| item[:source] }.join(', ')}. See storage/README.md"
      end
      config.storage_links.each do |link|
        source = config.home_path(link['source'])
        destination = File.join(PATH, link['destination'])
        next if alias_state(source, destination) == 'ok'
        FileUtils.mkdir_p(destination)
        FileUtils.mkdir_p(File.dirname(source))
        Dir.rmdir(source) if File.directory?(source) && !File.symlink?(source)
        File.symlink(destination, source)
      end
    end
  end
end
