# frozen_string_literal: true

require_relative "./lib/rewind/version"

Gem::Specification.new do |spec|
  spec.name    = "rewind-app"
  spec.version = Rewind::VERSION
  spec.authors = ["Nando Vieira"]
  spec.email   = ["me@fnando.com"]
  spec.metadata = {"rubygems_mfa_required" => "true"}

  spec.summary     = "Self-hosted media watching tracker."
  spec.description = spec.summary
  spec.license     = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 4.0")

  github_url = "https://github.com/fnando/rewind"
  github_tree_url = "#{github_url}/tree/v#{spec.version}"

  spec.homepage = github_url
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{github_url}/issues"
  spec.metadata["source_code_uri"] = github_tree_url
  spec.metadata["changelog_uri"] = "#{github_tree_url}/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{github_tree_url}/README.md"
  spec.metadata["license_uri"] = "#{github_tree_url}/LICENSE.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    `git ls-files -z`
      .split("\x0")
      .reject {|f| f.match(%r{^(test|spec|features)/}) }
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) {|f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "bcrypt"
  spec.add_dependency "dotenv"
  spec.add_dependency "erubi"
  spec.add_dependency "httpx"
  spec.add_dependency "irb"
  spec.add_dependency "mini_magick"
  spec.add_dependency "puma"
  spec.add_dependency "rack"
  spec.add_dependency "rackup"
  spec.add_dependency "sequel"
  spec.add_dependency "sinatra"
  spec.add_dependency "sinatra-contrib"
  spec.add_dependency "sqlite3"
  spec.add_dependency "thor"
  spec.add_dependency "tilt"
  spec.add_dependency "tzinfo"
  spec.add_dependency "tzinfo-data"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "minitest-utils"
  spec.add_development_dependency "rack-test"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "rubocop-fnando"
  spec.add_development_dependency "simplecov"
  spec.add_development_dependency "webmock"
end
