.PHONY: check build install publish
VERSION = $(shell grep VERSION lib/nextcloud_release_agent/version.rb | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')

check:
	ruby -c lib/nextcloud_release_agent/changelog_renderer.rb
	ruby -c lib/nextcloud_release_agent/cli.rb
	ruby -c lib/nextcloud_release_agent.rb
	ruby -c exe/nextcloud-release-agent

build: check
	rm -f nextcloud_release_agent-*.gem
	gem build nextcloud_release_agent.gemspec

install: build
	gem install --user-install nextcloud_release_agent-${VERSION}.gem

publish: build
	gem push nextcloud_release_agent-${VERSION}.gem
