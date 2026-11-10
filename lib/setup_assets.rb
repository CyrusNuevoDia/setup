# frozen_string_literal: true

require 'digest'

module Setup
  class AssetBundle
    FONT_EXTENSIONS = %w[.otf .ttf .ttc .otc .dfont].freeze
    CONTENT_DIRECTORIES = {'fonts' => 'fonts', 'alfred' => 'alfred/Alfred.alfredpreferences'}.freeze

    def initialize(path, stages)
      root = File.realpath(path)
      @files = stages.to_h do |stage|
        base = File.join(root, CONTENT_DIRECTORIES.fetch(stage))
        manifest = File.join(root, stage, 'manifest.json')
        entries = JSON.parse(File.read(manifest)).fetch('files')
        raise Error, "Empty #{stage} manifest" if entries.empty?
        files = entries.map do |entry|
          relative = entry.fetch('source')
          unless relative.is_a?(String) && relative.split('/', -1).all? { |part| !part.empty? && !%w[. ..].include?(part) && !part.match?(/[[:cntrl:]]/) }
            raise Error, "Invalid path in #{stage} manifest"
          end
          source = File.join(base, relative)
          unless File.file?(source) && File.realpath(source) == source && Digest::SHA256.file(source).hexdigest == entry.fetch('sha256')
            raise Error, "Missing or changed file in #{stage} bundle: #{relative}"
          end
          [relative, source]
        end
        raise Error, "Duplicate paths in #{stage} manifest" unless files.map(&:first).uniq.length == files.length
        files.select! { |relative, _source| FONT_EXTENSIONS.include?(File.extname(relative).downcase) } if stage == 'fonts'
        raise Error, "No installable files in #{stage} bundle" if files.empty?
        [stage, files]
      end
    end

    def files(stage)
      @files.fetch(stage)
    end

    def counts
      @files.transform_values(&:length)
    end
  end
end
