# frozen_string_literal: true

require "optparse"
require_relative "setup_config"
require_relative "setup_storage"
require_relative "setup_actions"

module Setup
  class CLI
    def self.run(argv, root)
      options = {home: Dir.home, with: [], json: !$stdout.tty?}
      parser = OptionParser.new do |flags|
        flags.banner = 'Usage: ./setup plan|apply|check|verify [options]'
        flags.on('--profile PROFILE', %w[work], 'Choose an install profile') { |value| options[:profile] = value }
        flags.on('--with IDS', Array, 'Include named optional apps') { |value| options[:with] = value }
        flags.on('--only STAGES', Array, 'Limit stages: ' + Config::STAGES.join(',')) { |value| options[:stages] = value }
        flags.on('--assets PATH', 'Read a private fonts and Alfred asset directory') { |value| options[:assets] = value }
        flags.on('--home PATH', 'Restore files to another existing home directory') { |value| options[:home] = value }
        flags.on('--dry-run', 'Preview apply without changing anything') { options[:dry_run] = true }
        flags.on('--json', 'Emit one JSON document') { options[:json] = true }
        flags.on('-h', '--help', 'Show help') { puts flags; return 0 }
      end
      command = argv.shift
      if %w[-h --help].include?(command) || command.nil?
        puts parser
        return 0
      end
      raise Error, "Unknown command: #{command}" unless %w[plan apply check verify].include?(command)
      parser.parse!(argv)
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
      options[:profile] ||= 'work' if command == 'verify'
      config = Config.new(root, options)
      actions = Actions.new(config)
      validate_inputs!(config, actions)
      result = case command
               when 'plan' then plan(config, actions)
               when 'apply'
                 if options[:dry_run]
                   plan(config, actions).merge(command: 'apply', dryRun: true)
                 else
                   apply(config, actions)
                 end
               when 'check' then check(config, actions)
               when 'verify' then verify(config, actions)
               end
      emit(result, options[:json])
      result[:status] == 'failed' ? 1 : result[:status] == 'pending' ? 2 : 0
    rescue Error, OptionParser::ParseError, SystemCallError, JSON::ParserError, KeyError => error
      emit({status: 'failed', error: error.message}, options ? options[:json] : true)
      1
    end

    def self.validate_inputs!(config, actions)
      if config.stages.include?('packages')
        raise Error, 'Missing brew/Brewfile' unless File.file?(File.join(config.root, 'brew/Brewfile'))
        raise Error, 'Missing mise config link' unless config.links.any? { |entry| entry['target'] == '.config/mise/config.toml' }
      end
    end

    def self.plan(config, actions)
      {
        command: 'plan', status: 'ok', profile: config.profile, home: config.home,
        stages: config.stages,
        storage: config.stages.include?('storage') ? config.storage_links.map { |entry| {source: config.home_path(entry['source']), destination: File.join(CodeVolume::PATH, entry['destination'])} } : [],
        packages: config.stages.include?('packages') ? {brewfile: 'brew/Brewfile', miseConfig: '.config/mise/config.toml', miseInstall: true, shellDependencies: config.clones} : nil,
        apps: config.stages.include?('apps') ? config.apps.map { |app| {id: app['id'], name: app['name'], installed: !!actions.installed_app_path(app), install: app['install']} } : [],
        links: config.stages.include?('links') ? config.links.map { |entry| actions.setting_state(entry) } : [],
        assets: config.assets&.counts,
        optionalApps: config.read('apps/manifest.json')['apps'].select { |app| app['profiles'].include?(config.profile) && !app['default'] && app.dig('install', 'type') != 'excluded' }.map { |app| {id: app['id'], name: app['name'], group: app['group']} }
      }
    end

    def self.apply(config, actions)
      raise Error, 'Run setup as your normal user, without sudo' if Process.uid.zero?
      alternate_home = config.home != File.realpath(Dir.home)
      if alternate_home && !(config.stages - %w[links fonts alfred]).empty?
        raise Error, '--home supports file restoration only; use --only links,fonts,alfred'
      end
      results = []
      # Resolve all repository inputs and profile selections before the first effect.
      config.stages.each do |stage|
        begin
          result = stage == 'alfred' ? actions.alfred(apply: true) : actions.public_send(stage)
          results << {stage: stage}.merge(result)
        rescue Error, SystemCallError => error
          results << {stage: stage, status: 'failed', error: error.message}
          break
        end
      end
      status = results.any? { |item| item[:status] == 'failed' } ? 'failed' : results.any? { |item| item[:status] == 'pending' } ? 'pending' : 'ok'
      {command: 'apply', status: status, profile: config.profile, results: results}
    end

    def self.check(config, actions)
      results = []
      config.stages.each do |stage|
        result = case stage
                 when 'storage' then check_storage(config)
                 when 'packages' then check_packages(config, actions)
                 when 'apps'
                   apps = config.apps.map { |app| {id: app['id'], status: actions.installed_app_path(app) ? 'ok' : 'pending', install: app['install']} }
                   {status: apps.all? { |app| app[:status] == 'ok' } ? 'ok' : 'pending', apps: apps}
                 when 'links'
                   pending = config.links.map { |entry| actions.setting_state(entry) }.reject { |entry| entry[:status] == 'ok' }
                   {status: pending.empty? ? 'ok' : 'pending', pending: pending}
                 when 'fonts' then actions.check_fonts
                 when 'alfred' then actions.alfred
                 end
        results << {stage: stage}.merge(result)
      end
      {command: 'check', status: results.all? { |item| item[:status] == 'ok' } ? 'ok' : 'pending', profile: config.profile, results: results}
    end

    def self.check_storage(config)
      CodeVolume.validate!
      missing = config.storage_links.reject do |entry|
        CodeVolume.alias_state(config.home_path(entry['source']), File.join(CodeVolume::PATH, entry['destination'])) == 'ok'
      end.map { |entry| entry['source'] }
      indexing, _error, indexing_status = Open3.capture3('/usr/bin/mdutil', '-s', CodeVolume::PATH)
      disabled = indexing_status.success? && indexing.include?('Indexing disabled.')
      {status: missing.empty? && disabled ? 'ok' : 'pending', missing: missing, spotlightIndexingDisabled: disabled, eventLogMarker: 'requires privileged confirmation of /Volumes/Code/.fseventsd/no_log', rebootUnlock: 'requires verification after reboot'}
    rescue Error => error
      {status: 'pending', message: error.message}
    end

    def self.check_packages(config, actions)
      mise = actions.executable('mise')
      brew = actions.executable('brew')
      return {status: 'pending', message: 'Install Homebrew and mise'} unless mise && brew
      config_path = config.home_path('.config/mise/config.toml')
      return {status: 'pending', message: 'Link the mise configuration'} unless File.file?(config_path)
      output, _error, status = Open3.capture3({'MISE_GLOBAL_CONFIG_FILE' => config_path}, mise, 'ls', '--missing', '--json', chdir: config.home)
      return {status: 'pending', message: 'mise cannot read the global configuration; run packages'} unless status.success?
      missing = JSON.parse(output)
      _output, _error, bundled = Open3.capture3({'HOMEBREW_NO_AUTO_UPDATE' => '1'}, brew, 'bundle', 'check', '--file', File.join(config.root, 'brew/Brewfile'), chdir: config.home)
      {status: missing.empty? && bundled.success? ? 'ok' : 'pending', missingMiseTools: missing, homebrewBundle: bundled.success?}
    rescue JSON::ParserError
      {status: 'pending', message: 'Unexpected mise output; inspect mise ls --missing --json'}
    end

    def self.verify(config, _actions)
      config.source_path('brew/Brewfile')
      {command: 'verify', status: 'ok', links: config.links.length, apps: config.apps.length, storageAliases: config.storage_links.length, assets: config.assets&.counts}
    end

    def self.emit(result, json)
      if json
        puts JSON.pretty_generate(result)
      else
        puts "#{result[:command] || 'setup'}: #{result[:status]}#{result[:profile] ? " (#{result[:profile]})" : ''}"
        puts result[:error] if result[:error]
        if result[:command] == 'plan' || result[:dryRun]
          puts "Stages: #{result[:stages].join(', ')}"
          puts "Storage aliases: #{result[:storage].length}; config links: #{result[:links].length}"
          result[:assets]&.each { |kind, count| puts "  #{kind}: #{count} files" }
          result[:apps].each { |app| puts "  #{app[:installed] ? 'installed' : app[:install]['type']}: #{app[:name]} (#{app[:id]})" }
          puts 'Optional apps (add --with id,id):'
          result[:optionalApps].each { |app| puts "  #{app[:id]}: #{app[:name]} [#{app[:group]}]" }
        elsif result[:results]
          result[:results].each { |item| puts "  #{item[:stage]}: #{item[:status]}#{item[:message] || item[:error] ? ' — ' + (item[:message] || item[:error]) : ''}" }
          puts 'Use --json for exact pending items and installation routes.'
        elsif result[:command] == 'verify'
          puts "#{result[:links]} links, #{result[:apps]} apps, #{result[:storageAliases]} storage aliases"
        end
      end
    end
  end
end
