# frozen_string_literal: true

require "test_helper"
require "zlib"
require "stringio"
require "rubygems/package"

class TimezoneDataTest < Minitest::Test
  TZ = Rewind::Services::TimezoneData

  def setup
    @config = Rewind::Config.new
    @config.data_dir = Dir.mktmpdir("rewind-tzdata-")
  end

  # Builds a GitHub-style source tarball: files live under a top-level
  # "<owner>-<repo>-<sha>/" directory that extraction must strip.
  def tarball(files, prefix = "tzinfo-tzinfo-data-abc1234")
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) do |gz|
      Gem::Package::TarWriter.new(gz) do |tar|
        files.each do |path, content|
          full = "#{prefix}/#{path}"
          tar.add_file_simple(full, 0o644, content.bytesize) do |f|
            f.write(content)
          end
        end
      end
    end
    io.string
  end

  def version_rb(version)
    "module TZInfo\n module Data\n VERSION = '#{version}'\n end\nend\n"
  end

  def stub_release(version, tarball_url: "https://codeload.test/tzdata.tgz")
    stub_request(:get, TZ::RELEASES_URL).to_return(
      status: 200,
      headers: {"content-type" => "application/json"},
      body: {tag_name: "v#{version}", tarball_url:}.to_json
    )
    tarball_url
  end

  test "extract_lib! strips the top dir and keeps only lib/" do
    dest = Dir.mktmpdir
    tgz = tarball(
      "lib/tzinfo/data/version.rb" => version_rb("1.2099.1"),
      "README.md" => "ignore me"
    )

    TZ.extract_lib!(tgz, dest)

    assert_path_exists File.join(dest, "lib/tzinfo/data/version.rb")
    refute_path_exists File.join(dest, "README.md") # non-lib entry skipped
  end

  test "check_and_update! installs a newer release and requests a restart" do
    url = stub_release("1.2099.1")
    stub_request(:get, url).to_return(
      status: 200,
      body: tarball("lib/tzinfo/data/version.rb" => version_rb("1.2099.1"))
    )

    Dir.mktmpdir do |cwd|
      Dir.chdir(cwd) { TZ.check_and_update!(@config) }

      installed = File.join(@config.data_dir,
                            "tzinfo-data/lib/tzinfo/data/version.rb")

      assert_path_exists installed
      assert_path_exists File.join(cwd, "tmp/restart.txt")
    end

    state = JSON.parse(File.read(File.join(@config.data_dir,
                                           "tzinfo-data.json")))

    assert_equal "1.2099.1", state["installed_version"]
    assert state["last_checked_at"]
  end

  test "check_and_update! skips a release that isn't newer than the gem" do
    stub_release("1.2000.1") # older than the bundled gem; no tarball stub

    TZ.check_and_update!(@config)

    refute_path_exists File.join(@config.data_dir, "tzinfo-data")
    state = JSON.parse(File.read(File.join(@config.data_dir,
                                           "tzinfo-data.json")))

    assert state["last_checked_at"] # the attempt is still recorded
  end

  test "local_usable? only accepts a copy at least as new as the gem" do
    refute TZ.local_usable?(@config) # nothing on disk

    write_local_copy("1.2099.1")

    assert TZ.local_usable?(@config)

    write_local_copy("1.2000.1")

    refute TZ.local_usable?(@config) # older than the gem
  end

  test "seconds_until_due is zero without state, positive after a check" do
    assert_equal 0, TZ.seconds_until_due(@config, 3600)

    TZ.send(:update_state, @config, "last_checked_at" => Time.now.utc.iso8601)

    assert_operator TZ.seconds_until_due(@config, 3600), :>, 0
  end

  def write_local_copy(version)
    dir = File.join(@config.data_dir, "tzinfo-data", "lib", "tzinfo", "data")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "version.rb"), version_rb(version))
  end
end
