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
        say "\nShare the password with the user. They will be forced to change it on first login."
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

      say "USERNAME             NAME                 CREATED              LAST LOGIN          "
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
    def run_server
      CLI.load_env!(options[:env])
      require_relative "migrator"
      if options[:migrate]
        Rewind::Migrator.migrate!
      elsif Rewind::Migrator.pending?
        say "Pending migrations detected. Run `rewind migrate` or pass --migrate."
      end
      Rewind.config.port = options[:port] if options[:port]
      Rewind.config.host = options[:host] if options[:host]
      app = Rewind.application
      display_host = %w[0.0.0.0 ::].include?(Rewind.config.host) ? "localhost" : Rewind.config.host
      say "Rewind listening on http://#{display_host}:#{Rewind.config.port}/"
      require "rackup"
      Rackup::Handler.default.run(app, Host: Rewind.config.host,
                                       Port: Rewind.config.port)
    end
    map "run" => :run_server

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
