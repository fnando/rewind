# frozen_string_literal: true

require "thor"
require "dotenv"

module Rewind
  class UsersCLI < Thor
    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    desc "new", "Create a new user with a generated password"
    option :username, type: :string, required: true
    option :name, type: :string
    def new
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      password = Rewind::Services::PasswordGenerator.call
      user = Rewind::User.new(
        username: options[:username],
        name: options[:name]
      )
      user.password = password
      user.must_change_password = true

      if user.valid?
        user.save
        say_header("User created")
        say_kv("username", user.username)
        say_kv("password", password)
        say "\nShare the password with the user. They will be forced " \
            "to change it on first login."
      else
        say "Could not create user:"
        user.errors.each {|field, errs| say "  #{field}: #{errs.join(', ')}" }
        exit 1
      end
    end

    desc "update", "Update a user"
    option :username, type: :string, required: true
    option :new_password, type: :boolean, default: false,
                          desc: "Regenerate the password"
    option :name, type: :string
    option :rating_style, type: :string, enum: %w[stars thumbs]
    def update
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      user = Rewind::User.where(username: options[:username]).first
      abort("User not found: #{options[:username]}") unless user

      user.set(name: options[:name]) if options.key?(:name)
      user.set(rating_style: options[:rating_style]) if options[:rating_style]

      password = nil
      if options[:new_password]
        password = Rewind::Services::PasswordGenerator.call
        user.password = password
        user.must_change_password = true
      end

      user.save
      say_header("User updated")
      say_kv("username", user.username)
      say_kv("password", password) if password
    end

    desc "delete", "Delete a user and their data"
    option :username, type: :string, required: true
    option :yes, type: :boolean, default: false
    def delete
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      user = Rewind::User.where(username: options[:username]).first
      abort("User not found: #{options[:username]}") unless user

      unless options[:yes]
        print "Delete #{user.username} and all their data? [y/N] "
        answer = $stdin.gets.to_s.strip.downcase
        abort("Aborted.") unless %w[y yes].include?(answer)
      end

      user.destroy
      say "Deleted #{options[:username]}."
    end

    desc "list", "List users"
    def list
      Rewind::CLI.load_env!(options[:env])
      Rewind::CLI.boot_db!
      rows = Rewind::User.order(:username).all
      if rows.empty?
        say "No users yet. Run: rewind users:new --username USERNAME"
        return
      end

      say "USERNAME             NAME                 " \
          "CREATED              LAST LOGIN          "
      rows.each do |u|
        say format(
          "%-20s %-20s %-20s %-20s",
          u.username,
          u.name || "-",
          u.created_at&.strftime("%Y-%m-%d %H:%M") || "-",
          u.last_login_at&.strftime("%Y-%m-%d %H:%M") || "-"
        ).rstrip
      end
    end

    no_commands do
      def say_header(text)
        say "\n== #{text} =="
      end

      def say_kv(k, v)
        say format("  %-10s %s", "#{k}:", v)
      end
    end
  end

  class WebhooksCLI < Thor
    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    def self.exit_on_failure?
      true
    end

    desc "new", "Allowlist a media server instance and print its webhook URL"
    option :url, type: :string, required: true
    option :type, type: :string, default: "jellyfin"
    def new
      boot!
      token = Rewind::Webhook.generate_token
      webhook = Rewind::Webhook.new(type: options[:type], url: options[:url])
      webhook.token = token

      if webhook.valid?
        webhook.save
        say_header("Instance allowlisted")
        say_kv("type", webhook.type)
        say_kv("url", webhook.url)
        say_kv("webhook", webhook_url(webhook, token))
        say "\nPaste that webhook URL into Jellyfin and include " \
            "\"ServerUrl\": \"{{ServerUrl}}\"\nin the template."
      else
        say "Could not allowlist instance:"
        webhook.errors.each do |field, errs|
          say "  #{field}: #{errs.join(', ')}"
        end
        exit 1
      end
    end

    LIST_FORMAT = "%-10s %-40s %-8s %-18s %s"

    desc "list", "List allowlisted instances"
    def list
      boot!
      rows = Rewind::Webhook.order(:type, :url).all
      if rows.empty?
        say "No instances yet. Run: rewind webhooks:new --url URL"
        return
      end

      say format(LIST_FORMAT, "TYPE", "URL", "ENABLED", "LAST EVENT", "USERS")
      rows.each do |webhook|
        say format(
          LIST_FORMAT,
          webhook.type,
          webhook.url,
          webhook.enabled? ? "yes" : "no",
          webhook.last_event_at&.strftime("%Y-%m-%d %H:%M") || "-",
          webhook.integrations_dataset.count
        )
      end
    end

    desc "update", "Update an allowlisted instance"
    option :url, type: :string, required: true
    option :enabled, type: :boolean,
                     desc: "Accept (--enabled) or reject (--no-enabled) events"
    def update
      boot!
      webhook = find_instance(options[:url])
      webhook.set(enabled: options[:enabled]) if options.key?(:enabled)
      webhook.save
      say_header("Instance updated")
      say_kv("url", webhook.url)
      say_kv("enabled", webhook.enabled? ? "yes" : "no")
    end

    desc "rotate", "Regenerate an instance's webhook token"
    option :url, type: :string, required: true
    def rotate
      boot!
      webhook = find_instance(options[:url])
      token = webhook.rotate_token!
      say_header("Token rotated")
      say_kv("webhook", webhook_url(webhook, token))
      say "\nThe previous webhook URL no longer works."
    end

    desc "delete", "Remove an allowlisted instance and its user mappings"
    option :url, type: :string, required: true
    option :yes, type: :boolean, default: false
    def delete
      boot!
      webhook = find_instance(options[:url])
      unless options[:yes]
        print "Delete #{webhook.url} and all its user mappings? [y/N] "
        answer = $stdin.gets.to_s.strip.downcase
        abort("Aborted.") unless %w[y yes].include?(answer)
      end

      webhook.destroy
      say "Deleted #{webhook.url}."
    end

    no_commands do
      def boot!
        Rewind::CLI.load_env!(options[:env])
        Rewind::CLI.boot_db!
      end

      def find_instance(url)
        normalized = Rewind::Webhook.normalize_url(url)
        webhook = Rewind::Webhook.where(url: normalized).first
        abort("Instance not found: #{url}") unless webhook
        webhook
      end

      # Build the public webhook URL from the first allowed host, falling back
      # to the bare path when no hosts are configured.
      def webhook_url(webhook, token)
        path = "/webhooks/#{webhook.type}/#{token}"
        host = Rewind.config.allowed_hosts.first
        host ? "https://#{host}#{path}" : path
      end

      def say_header(text)
        say "\n== #{text} =="
      end

      def say_kv(k, v)
        say format("  %-10s %s", "#{k}:", v)
      end
    end
  end

  class CLI < Thor
    check_unknown_options!

    def self.exit_on_failure?
      true
    end

    def self.load_env!(path)
      return unless path

      abort("env file not found: #{path}") unless File.exist?(path)
      Dotenv.load(path)
      Rewind.config = Config.new
    end

    def self.boot_db!
      require_relative "migrator"
      Rewind::Migrator.migrate! if ENV["REWIND_AUTO_MIGRATE"] == "1"
      Rewind.boot!
      require_relative "services/password_generator"
    end

    class_option :env, type: :string,
                       desc: "Path to a dotenv file to load before executing"

    desc "run", "Start the Rewind web server"
    option :port, type: :numeric
    option :host, type: :string
    option :migrate, type: :boolean, default: false,
                     desc: "Run pending migrations before booting"
    option :verbose, type: :boolean, default: false, aliases: "-v",
                     desc: "Log every recorded and skipped webhook event"
    def run_server
      CLI.load_env!(options[:env])
      Rewind.logger.level = Logger::INFO if options[:verbose]
      require_relative "migrator"
      if options[:migrate] || ENV["REWIND_AUTO_MIGRATE"] == "1"
        Rewind::Migrator.migrate!
      elsif Rewind::Migrator.pending?
        abort "Pending migrations detected. " \
              "Run `rewind migrate` or pass --migrate."
      end
      Rewind.config.port = options[:port] if options[:port]
      Rewind.config.host = options[:host] if options[:host]
      app = Rewind.application
      wildcard = %w[0.0.0.0 ::].include?(Rewind.config.host)
      display_host = wildcard ? "localhost" : Rewind.config.host
      say "Rewind listening on http://#{display_host}:#{Rewind.config.port}/"

      require "puma"
      require "puma/configuration"
      require "puma/launcher"

      plugins = %w[tmp_restart] | Rewind.config.puma_plugins
      conf = Puma::Configuration.new do |c|
        c.bind "tcp://#{Rewind.config.host}:#{Rewind.config.port}"
        c.app app
        plugins.each {|name| c.plugin(name) }
      end
      # Pass the original ARGV so Puma's restart (tmp_restart) re-execs the full
      # `rewind run ...` command instead of a bare `rewind`.
      Puma::Launcher.new(conf, argv: ARGV).run
    end
    map "run" => :run_server

    desc "restart", "Restart a running server (via Puma's tmp_restart plugin)"
    def restart
      path = File.join(Dir.pwd, "tmp", "restart.txt")
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.touch(path)
      say "Touched #{path}; a running server will restart."
    end

    desc "migrate", "Run all pending database migrations"
    def migrate
      CLI.load_env!(options[:env])
      require_relative "migrator"
      Rewind::Migrator.migrate!
      say "Migrations complete."
    end

    desc "console", "Launch an IRB console with models loaded"
    def console
      CLI.load_env!(options[:env])
      CLI.boot_db!
      require "irb"
      ARGV.clear
      IRB.start
    end

    desc "version", "Print the Rewind version"
    def version
      say Rewind::VERSION
    end

    desc "config", "Print the resolved configuration"
    def config_show
      CLI.load_env!(options[:env])
      Rewind.config.to_h.each do |k, v|
        display = v.nil? || (v.respond_to?(:empty?) && v.empty?) ? "(unset)" : v
        say format("  %-20s %s", "#{k}:", display)
      end
    end
    map "config" => :config_show

    desc "users SUBCOMMAND", "Manage users (new, update, delete, list)"
    subcommand "users", UsersCLI

    desc "webhooks SUBCOMMAND",
         "Allowlist media servers (new, list, update, rotate, delete)"
    subcommand "webhooks", WebhooksCLI

    def self.start(given_args = ARGV, config = {})
      # Allow colon form: users:new -> users new
      args = given_args.dup
      if args.first.is_a?(String) && args.first.include?(":")
        head, tail = args.shift.split(":", 2)
        args.unshift(head, tail)
      end
      super(args, config)
    end
  end
end

require_relative "services/password_generator"
