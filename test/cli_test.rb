# frozen_string_literal: true

require "test_helper"
require "stringio"

class CLITest < Minitest::Test
  def capture
    out = $stdout
    err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = out
    $stderr = err
  end

  def with_env(vars)
    original = vars.keys.to_h {|k| [k, ENV.fetch(k, nil)] }
    vars.each {|k, v| ENV[k] = v }
    yield
  ensure
    original.each {|k, v| ENV[k] = v }
  end

  def puma_options(config)
    conf = Rewind::CLI.puma_configuration(->(_env) { [200, {}, []] }, config:)
    conf.clamp
    conf.options
  end

  test "puma_configuration applies workers and threads" do
    config = Rewind::Config.new
    config.workers = 3
    config.threads = 8
    opts = puma_options(config)

    assert_equal 3, opts[:workers]
    assert_equal 8, opts[:min_threads]
    assert_equal 8, opts[:max_threads]
  end

  test "puma_configuration leaves Puma defaults when workers/threads are 0" do
    config = Rewind::Config.new # defaults to 0/0

    assert_equal 0, puma_options(config)[:workers] # single mode
  end

  test "resolve_log_level maps verbose to info and defaults to error" do
    resolve = ->(opts) { Rewind::CLI.resolve_log_level(opts) }

    assert_equal Logger::INFO, resolve.call(verbose: true)
    assert_equal Logger::INFO, resolve.call(verbose_level: "info")
    assert_equal Logger::DEBUG, resolve.call(verbose_level: "debug")
    # An explicit level wins over the --verbose shortcut.
    both = resolve.call(verbose: true, verbose_level: "debug")

    assert_equal Logger::DEBUG, both
    assert_equal Logger::ERROR, resolve.call({})
  end

  test "puma_configuration registers a before_fork hook only in cluster mode" do
    single = Rewind::Config.new

    assert_empty Array(puma_options(single)[:before_fork])

    clustered = Rewind::Config.new
    clustered.workers = 2

    assert_equal 1, Array(puma_options(clustered)[:before_fork]).size
  end

  test "puma_configuration passes the environment through" do
    config = Rewind::Config.new
    config.environment = "staging"

    assert_equal "staging", puma_options(config)[:environment]
  end

  test "environment defaults to production with APP_ENV/RACK_ENV fallbacks" do
    with_env("APP_ENV" => nil, "RACK_ENV" => nil) do
      assert_equal "production", Rewind::Config.new.environment
    end
    with_env("APP_ENV" => nil, "RACK_ENV" => "staging") do
      assert_equal "staging", Rewind::Config.new.environment
    end
    with_env("APP_ENV" => "qa", "RACK_ENV" => "staging") do
      assert_equal "qa", Rewind::Config.new.environment # APP_ENV wins
    end
  end

  test "load_env! exports the resolved environment as APP_ENV and RACK_ENV" do
    original_config = Rewind.config

    with_env("APP_ENV" => nil, "RACK_ENV" => nil) do
      Rewind::CLI.load_env!(environment: "staging") # explicit flag wins

      assert_equal "staging", ENV.fetch("APP_ENV")
      assert_equal "staging", ENV.fetch("RACK_ENV")
      assert_equal "staging", Rewind.config.environment
    end

    with_env("APP_ENV" => nil, "RACK_ENV" => nil) do
      Rewind::CLI.load_env!({}) # nothing set anywhere

      assert_equal "production", ENV.fetch("RACK_ENV")
    end
  ensure
    Rewind.config = original_config
  end

  test "users:new creates a user with a generated password" do
    out, = capture { Rewind::CLI.start(["users:new", "--username", "alice"]) }

    assert_includes out, "User created"
    assert_includes out, "alice"
    user = Rewind::User.where(username: "alice").first

    assert user
    assert user.must_change_password
  end

  test "users:update --new-password resets the password" do
    user = create_user(username: "bob")
    user.update(must_change_password: false)
    out, = capture { Rewind::CLI.start(["users:update", "--username", "bob", "--new-password"]) }

    assert_includes out, "User updated"
    user.reload

    assert user.must_change_password
  end

  test "users:delete removes the user" do
    create_user(username: "cathy")
    capture { Rewind::CLI.start(["users:delete", "--username", "cathy", "--yes"]) }

    assert_nil Rewind::User.where(username: "cathy").first
  end

  test "users:list prints users" do
    create_user(username: "dan")
    out, = capture { Rewind::CLI.start(["users:list"]) }

    assert_includes out, "dan"
  end

  def create_source(url)
    user = Rewind::User.new(username: "u#{SecureRandom.hex(3)}")
    user.password = "a-secure-password-123"
    user.save
    source = Rewind::Source.new(user_id: user.id, type: "jellyfin", url:,
                                external_user_id: "jf-1", instance_id: "srv-1")
    source.credentials = {"access_token" => "tok"}
    source.save
    source
  end

  test "sources:list prints connected sources" do
    create_source("https://room.example.com")
    out, = capture { Rewind::CLI.start(["sources:list"]) }

    assert_includes out, "room.example.com"
  end

  test "sources:disable disables a source" do
    source = create_source("https://off.example.com")
    capture do
      Rewind::CLI.start(["sources:disable", "--id", source.id.to_s])
    end

    refute source.refresh.enabled?
  end

  test "sources:enable re-enables a source" do
    source = create_source("https://on.example.com")
    source.update(enabled: false)
    capture { Rewind::CLI.start(["sources:enable", "--id", source.id.to_s]) }

    assert source.refresh.enabled?
  end

  test "sources:delete removes a source" do
    source = create_source("https://del.example.com")
    capture do
      Rewind::CLI.start(["sources:delete", "--id", source.id.to_s, "--yes"])
    end

    assert_nil Rewind::Source[source.id]
  end
end
