require_relative "lib/nextcloud_release_agent/version"

Gem::Specification.new do |spec|
  spec.name = "nextcloud_release_agent"
  spec.version = NextcloudReleaseAgent::VERSION
  spec.authors = ["Anupam Kumar"]
  spec.email = ["kyteinsky@gmail.com"]

  spec.summary = "Ruby CLI for releasing Nextcloud apps using `git` and `gh`."
  spec.description = "Automates changelog updates, semver bumps, PR creation, tagging, releases, and workflow monitoring for Nextcloud app repositories."
  spec.homepage = "https://github.com/kyteinsky/nextcloud_release_agent"
  spec.license = "AGPL-3.0-only"

  spec.files = Dir.glob("{exe,lib}/**/*") + %w[Gemfile README.md nextcloud_release_agent.gemspec]
  spec.bindir = "exe"
  spec.executables = ["nextcloud-release-agent"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"
  spec.add_runtime_dependency "rexml", "~> 3.2"
end
