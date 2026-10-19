# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Rewind
  module Services
    # Keeps the IANA time zone database current on a long-running server without
    # redeploys. The bundled `tzinfo-data` gem freezes at install time, but
    # governments keep changing DST rules, so a once-a-day thread checks
    # `tzinfo/tzinfo-data`'s latest GitHub release and, when it's newer, unpacks
    # the pre-generated Ruby data into the data dir. On boot we load that copy
    # (if present and at least as new as the gem) via TZInfo's RubyDataSource.
    #
    # Required Ruby can't be hot-reloaded, so a freshly downloaded version only
    # takes effect on the next boot — we request a restart (Puma's tmp_restart)
    # so it applies promptly. A JSON state file makes the daily cadence survive
    # restarts, and every version decision is gated so we never regress below
    # the gem or break boot.
    module TimezoneData
      REPO = "tzinfo/tzinfo-data"
      RELEASES_URL =
        "https://api.github.com/repos/#{REPO}/releases/latest".freeze
      USER_AGENT = "rewind"
      CHECK_INTERVAL = 86_400 # seconds — once a day

      class << self
        # --- Boot: prefer the synced copy when it's at least as new as the gem.

        def install_local_source!(config = Rewind.config)
          return unless local_usable?(config)

          version = local_version(config)
          $LOAD_PATH.unshift(File.join(local_dir(config), "lib"))
          require "tzinfo"
          TZInfo::DataSource.set(:ruby)
          Rewind.logger.info("[tzdata] using synced data #{version}")
        rescue StandardError => error
          # Never let a bad copy break boot; fall back to the bundled gem.
          Rewind.logger.error("[tzdata] load failed: #{error.message}")
        end

        def local_usable?(config = Rewind.config)
          version = local_version(config)
          !version.nil? &&
            Gem::Version.new(version) >= Gem::Version.new(gem_version)
        end

        # --- Daily background thread -------------------------------------

        def start_thread(interval: CHECK_INTERVAL, config: Rewind.config)
          Thread.new do
            loop do
              wait = seconds_until_due(config, interval)
              sleep(wait) if wait.positive?
              begin
                check_and_update!(config)
              rescue StandardError => error
                Rewind.logger.error("[tzdata] #{error.message}")
              end
            end
          end
        end

        def seconds_until_due(config = Rewind.config, interval = CHECK_INTERVAL)
          last = read_state(config)["last_checked_at"]
          return 0 unless last

          wait = (Time.parse(last) + interval) - Time.now
          wait.positive? ? wait : 0
        rescue ArgumentError
          0 # unparseable timestamp → check now
        end

        # Checks the latest release and installs it when it beats both the gem
        # and any copy already on disk. Records the attempt either way, so a
        # failed check still counts toward the daily cadence.
        def check_and_update!(config = Rewind.config)
          latest = fetch_latest
          update_state(config, "last_checked_at" => now_iso)
          return unless latest
          return unless newer?(latest[:version], current_version(config))

          install!(latest, config)
          update_state(config, "installed_version" => latest[:version],
                               "last_checked_at" => now_iso)
          request_restart!
          Rewind.logger.info(
            "[tzdata] updated time zone data to #{latest[:version]}; " \
            "restarting to apply"
          )
        end

        # --- GitHub ------------------------------------------------------

        def fetch_latest
          body = http_get(RELEASES_URL)
          return unless body

          data = JSON.parse(body)
          version = data["tag_name"].to_s.delete_prefix("v")
          url = data["tarball_url"].to_s
          return if version.empty? || url.empty?

          {version:, tarball_url: url}
        rescue JSON::ParserError
          nil
        end

        def install!(latest, config = Rewind.config)
          bytes = http_get(latest[:tarball_url], follow: true)
          raise "download failed for #{latest[:version]}" unless bytes

          incoming = "#{local_dir(config)}.incoming"
          FileUtils.rm_rf(incoming)
          extract_lib!(bytes, incoming)
          unless File.exist?(version_file(incoming))
            FileUtils.rm_rf(incoming)
            raise "archive missing tzinfo data"
          end

          final = local_dir(config)
          FileUtils.rm_rf(final)
          FileUtils.mv(incoming, final)
        end

        # Unpacks only the `lib/` subtree of the GitHub source tarball into
        # +dest+, stripping the top-level "<owner>-<repo>-<sha>/" directory.
        def extract_lib!(tar_gz, dest)
          require "zlib"
          require "stringio"
          require "rubygems/package"

          Zlib::GzipReader.wrap(StringIO.new(tar_gz)) do |gz|
            Gem::Package::TarReader.new(gz) do |tar|
              tar.each {|entry| extract_entry(entry, dest) }
            end
          end
        end

        private def extract_entry(entry, dest)
          inner = entry.full_name.split("/", 2)[1] # drop the top-level dir
          return unless inner&.start_with?("lib/")

          target = File.join(dest, inner)
          if entry.directory?
            FileUtils.mkdir_p(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, entry.read)
          end
        end

        private def http_get(url, follow: false)
          require "httpx"
          # Bounded so a network blip can never hang the daily thread forever.
          client = HTTPX.with(
            headers: {"user-agent" => USER_AGENT},
            timeout: {connect_timeout: 10, operation_timeout: 30}
          )
          client = client.plugin(:follow_redirects) if follow
          response = client.get(url)
          return if response.is_a?(HTTPX::ErrorResponse)
          return unless response.status == 200

          response.to_s
        end

        # --- Versions ----------------------------------------------------

        private def current_version(config = Rewind.config)
          [local_version(config), gem_version].compact
                                              .max_by {|version| Gem::Version.new(version) }
        end

        private def local_version(config = Rewind.config)
          file = version_file(local_dir(config))
          return unless File.exist?(file)

          File.read(file)[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
        end

        private def gem_version
          Gem::Specification.find_by_name("tzinfo-data").version.to_s
        rescue StandardError
          "0"
        end

        private def newer?(candidate, baseline)
          Gem::Version.new(candidate) > Gem::Version.new(baseline)
        end

        # --- Paths / state ----------------------------------------------

        private def local_dir(config = Rewind.config)
          File.join(config.data_dir, "tzinfo-data")
        end

        private def version_file(root)
          File.join(root, "lib", "tzinfo", "data", "version.rb")
        end

        private def state_path(config)
          File.join(config.data_dir, "tzinfo-data.json")
        end

        private def read_state(config)
          JSON.parse(File.read(state_path(config)))
        rescue StandardError
          {}
        end

        private def update_state(config, attrs)
          FileUtils.mkdir_p(config.data_dir)
          File.write(state_path(config),
                     JSON.pretty_generate(read_state(config).merge(attrs)))
        end

        private def request_restart!
          path = File.join(Dir.pwd, "tmp", "restart.txt")
          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.touch(path)
        end

        private def now_iso
          Time.now.utc.iso8601
        end
      end
    end
  end
end
