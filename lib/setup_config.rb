# frozen_string_literal: true

require "json"
require "pathname"

module Setup
  class Error < StandardError; end

  def self.linked_to?(target, source)
    File.symlink?(target) && File.realpath(target) == File.realpath(source)
  rescue SystemCallError
    false
  end

  class Config
    STAGES = %w[storage packages apps links].freeze
    attr_reader :root, :home, :profile, :stages, :apps, :links, :storage_links, :clones

    def initialize(root, options)
      @root = File.realpath(root)
      @home = File.realpath(options.fetch(:home))
      @profile = options.fetch(:profile, 'work')
      raise Error, "Choose --profile work" unless %w[work].include?(profile)
      requested_stages = options.fetch(:stages, STAGES)
      unknown = requested_stages - STAGES
      raise Error, "Unknown stages: #{unknown.join(', ')}" unless unknown.empty?
      raise Error, 'Duplicate stages are not allowed' unless requested_stages.uniq.length == requested_stages.length
      @stages = STAGES.select { |stage| requested_stages.include?(stage) }
      raise Error, "Select at least one stage" if stages.empty?
      manifest = read("apps/manifest.json").fetch("apps")
      validate_apps(manifest)
      selected = options.fetch(:with, [])
      raise Error, "Unknown apps: #{(selected - manifest.map { |app| app['id'] }).join(', ')}" unless (selected - manifest.map { |app| app['id'] }).empty?
      forbidden = manifest.select { |app| selected.include?(app['id']) && (!app['profiles'].include?(profile) || app.dig('install', 'type') == 'excluded') }
      raise Error, "Apps excluded from #{profile}: #{forbidden.map { |app| app['id'] }.join(', ')}" unless forbidden.empty?
      @apps = manifest.select { |app| app['profiles'].include?(profile) && (app['default'] || selected.include?(app['id'])) && app.dig('install', 'type') != 'excluded' }
      @links = read("config/links.json").fetch("links")
      targets = links.map do |link|
        raise Error, "Invalid config restore mode" unless [nil, 'link', 'copy-if-missing'].include?(link['mode'])
        source_path(link.fetch("source"))
        target = home_path(link.fetch("target"))
        raise Error, "Link individual agent files, not #{link['target']}" if %w[.codex .claude .agents].include?(link['target'])
        target
      end
      raise Error, "Duplicate config link targets" unless targets.uniq.length == targets.length
      @storage_links = read("storage/layout.json").fetch("links")
      storage_links.each { |link| home_path(link.fetch("source")); relative!(link.fetch("destination")) }
      dependencies = File.join(root, "config/dependencies.json")
      @clones = File.file?(dependencies) ? read("config/dependencies.json").fetch("clones") : []
      clones.each do |clone|
        home_path(clone.fetch("target"))
        raise Error, "Dependency URL must use HTTPS" unless clone.fetch("url").start_with?("https://")
      end
    rescue JSON::ParserError, KeyError => error
      raise Error, "Invalid manifest: #{error.message}"
    end

    def read(path)
      JSON.parse(File.read(File.join(root, path)))
    rescue Errno::ENOENT
      raise Error, "Missing #{path}; check the repository files"
    end

    def relative!(value)
      unless value.is_a?(String) && !value.empty? && !value.match?(/[[:cntrl:]]/) && !Pathname.new(value).absolute? && value.split('/', -1).none? { |part| part.empty? || %w[. ..].include?(part) }
        raise Error, "Expected a relative path without traversal"
      end
      value
    end

    def source_path(value)
      path = File.join(root, relative!(value))
      raise Error, "Missing source: #{value}" unless File.exist?(path)
      raise Error, "Source escapes setup: #{value}" unless File.realpath(path).start_with?(root + '/')
      path
    end

    def home_path(value)
      File.join(home, relative!(value))
    end

    private

    def validate_apps(manifest)
      ids = manifest.map { |app| app.fetch('id') }
      raise Error, "Duplicate app IDs" unless ids.uniq.length == ids.length
      manifest.each do |app|
        raise Error, "Invalid app ID" unless app['id'].is_a?(String) && app['id'].match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        raise Error, "Invalid profiles for #{app['id']}" unless app.fetch('profiles').is_a?(Array) && (app['profiles'] - %w[work]).empty?
        raise Error, "Invalid install route for #{app['id']}" unless %w[cask mas manual system excluded].include?(app.dig('install', 'type'))
        if %w[cask mas].include?(app.dig('install', 'type'))
          raise Error, "Missing install ID for #{app['id']}" unless app.dig('install', 'id').is_a?(String) && app['install']['id'].match?(/\A[a-zA-Z0-9][a-zA-Z0-9@+._\/-]*\z/)
        end
        raise Error, "Invalid paths for #{app['id']}" unless app.fetch('paths').all? { |path| path.start_with?('/Applications/') && !path.split('/').include?('..') }
      end
    end
  end
end
