# frozen_string_literal: true

require "digest"
require "time"

module Setup
  class Actions
    attr_reader :config

    def initialize(config)
      @config = config
      @backup_root = nil
    end

    def backup(path)
      return unless File.exist?(path) || File.symlink?(path)
      @backup_root ||= File.join(config.home, '.setup-backups', Time.now.utc.strftime('%Y%m%dT%H%M%S') + "-#{Process.pid}")
      destination = File.join(@backup_root, path.sub(config.home + '/', ''))
      raise Error, "Backup already exists: #{destination}" if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mkdir_p(File.dirname(destination), mode: 0700)
      FileUtils.mv(path, destination)
    end

    def link(source, target)
      return if Setup.linked_to?(target, source)
      backup(target)
      FileUtils.mkdir_p(File.dirname(target))
      File.symlink(source, target)
    end

    def links
      copied = 0
      config.links.each do |entry|
        source = config.source_path(entry['source'])
        target = config.home_path(entry['target'])
        if entry['mode'] == 'copy-if-missing'
          # App-owned settings must stay native so runtime registration writes cannot reach Git.
          backup(target) if Setup.linked_to?(target, source)
          unless File.exist?(target) || File.symlink?(target)
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(source, target)
            File.chmod(0600, target)
            copied += 1
          end
        else
          link(source, target)
        end
      end
      files = config.links.map { |entry| setting_state(entry) }
      {status: files.all? { |file| file[:status] == 'ok' } ? 'ok' : 'pending', linked: config.links.count { |entry| entry['mode'] != 'copy-if-missing' }, copied: copied, files: files, backups: @backup_root}
    end

    def setting_state(entry)
      source = config.source_path(entry['source'])
      target = config.home_path(entry['target'])
      mode = entry['mode'] || 'link'
      current = mode == 'copy-if-missing' ? !File.symlink?(target) && same_file?(source, target) : Setup.linked_to?(target, source)
      state = {source: entry['source'], target: target, mode: mode, status: current ? 'ok' : 'pending'}
      if !current && mode == 'copy-if-missing'
        state[:message] = 'Merge these preferences into the existing file and preserve local authentication and app-managed sections.'
      end
      state
    end

    def same_file?(source, target)
      File.file?(target) && File.size(source) == File.size(target) && Digest::SHA256.file(source).digest == Digest::SHA256.file(target).digest
    end

    def executable(name)
      paths = ['/opt/homebrew/bin', '/usr/local/bin', config.home_path('.local/bin')] + ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
      paths.map { |base| File.join(base, name) }.find { |path| File.file?(path) && File.executable?(path) }
    end

    def command(*args, env: {}, chdir: config.home)
      # Child stdout must not corrupt the CLI's JSON payload or disclose shell configuration.
      success = system(env, *args, chdir: chdir, out: $stderr, err: $stderr)
      raise Error, "Command failed: #{args.join(' ')}" unless success
    end

    def packages
      CodeVolume.require_foundations!(config)
      unless executable('brew')
        return {status: 'pending', message: 'Install Homebrew from https://brew.sh, then rerun packages. Its installer needs interactive administrator access.'}
      end
      mise_link = config.links.find { |entry| entry['target'] == '.config/mise/config.toml' }
      raise Error, "Missing mise configuration link" unless mise_link
      link(config.source_path(mise_link['source']), config.home_path(mise_link['target']))
      command(executable('brew'), 'bundle', '--no-upgrade', '--file', File.join(config.root, 'brew/Brewfile'))
      mise = executable('mise')
      raise Error, "Homebrew bundle did not install mise" unless mise
      env = {'MISE_GLOBAL_CONFIG_FILE' => config.home_path('.config/mise/config.toml')}
      command(mise, 'trust', config.home_path('.config/mise/config.toml'), env: env)
      command(mise, 'install', env: env)
      command(mise, 'reshim', env: env)
      config.clones.each do |entry|
        target = config.home_path(entry['target'])
        next if File.directory?(File.join(target, '.git'))
        raise Error, "Dependency target exists: #{target}" if File.exist?(target) || File.symlink?(target)
        FileUtils.mkdir_p(File.dirname(target))
        args = ['git', 'clone', '--depth', '1']
        args += ['--branch', entry['branch']] if entry['branch']
        command(*(args + [entry['url'], target]))
      end
      {status: 'ok', message: 'Homebrew tools, mise runtimes, and shell dependencies installed', backups: @backup_root}
    end

    def installed_app_path(app)
      app['paths'].find do |path|
        next false unless File.directory?(path)
        expected = app.fetch('bundleIds', [])
        next true if expected.empty?
        plist = File.join(path, 'Contents/Info.plist')
        output, _error, status = Open3.capture3('/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleIdentifier', plist)
        status.success? && expected.include?(output.strip)
      end
    end

    def apps
      CodeVolume.require_foundations!(config)
      results = config.apps.map do |app|
        installed = installed_app_path(app)
        next({id: app['id'], status: 'ok', path: installed}) if installed
        install = app['install']
        if install['type'] == 'cask' && executable('brew')
          command(executable('brew'), 'install', '--cask', install['id'])
          installed = installed_app_path(app)
          raise Error, "#{app['name']} installed without the expected bundle identity/path; inspect before continuing" unless installed
          {id: app['id'], status: 'ok', path: installed}
        elsif install['type'] == 'system'
          {id: app['id'], status: 'pending', message: 'Bundled system app missing; inspect this macOS installation'}
        else
          {id: app['id'], status: 'pending', install: install}
        end
      end
      {status: results.any? { |app| app[:status] == 'pending' } ? 'pending' : 'ok', apps: results}
    end

    def storage
      CodeVolume.apply_links(config)
      {status: 'ok', aliases: config.storage_links.length, message: 'Fresh storage aliases established; reboot/unlock must be checked separately'}
    end
  end
end
