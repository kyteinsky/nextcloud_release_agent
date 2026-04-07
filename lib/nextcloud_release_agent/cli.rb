require "date"
require "json"
require "open3"
require "optparse"
require "pathname"
require "psych"
require "rexml/document"
require "shellwords"
require "tempfile"
require "time"

module NextcloudReleaseAgent
  class Error < StandardError; end

  CommandResult = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  CommitInfo = Struct.new(
    :sha,
    :author_name,
    :author_email,
    :message,
    :pr_number,
    :pr_title,
    :pr_body,
    :pr_url,
    :pr_author,
    :labels,
    :classification,
    :section,
    keyword_init: true
  )

  class Logger
    def info(message)
      puts("[INFO] #{message}")
    end

    def status(message)
      puts("[STEP] #{message}")
    end

    def warn(message)
      $stderr.puts("[WARN] #{message}")
    end

    def error(message)
      $stderr.puts("[ERROR] #{message}")
    end
  end

  class Shell
    def initialize(logger:, dry_run: false)
      @logger = logger
      @dry_run = dry_run
    end

    def capture(*command, chdir:, allow_failure: false, env: {})
      printable = command.shelljoin
      @logger.info("#{@dry_run ? 'would run' : 'running'}: #{printable}")
      return CommandResult.new(stdout: "", stderr: "", status: 0) if @dry_run

      stdout, stderr, status = Open3.capture3(env, *command, chdir: chdir)
      result = CommandResult.new(stdout: stdout, stderr: stderr, status: status.exitstatus)
      return result if status.success? || allow_failure

      raise Error, "command failed (#{status.exitstatus}): #{printable}\n#{stderr.strip}"
    end

    def system!(*command, chdir:, allow_failure: false, env: {})
      result = capture(*command, chdir: chdir, allow_failure: allow_failure, env: env)
      return result if result.status.zero? || allow_failure

      raise Error, "command failed (#{result.status}): #{command.shelljoin}\n#{result.stderr.strip}"
    end
  end

  class ChangelogFile
    SECTION_ORDER = ["Added", "Changed", "Fixed"].freeze

    def initialize(path)
      @path = Pathname(path)
    end

    def path
      @path
    end

    def data
      @data ||= Psych.safe_load(@path.read, aliases: false, permitted_classes: [], symbolize_names: false) || {}
    end

    def repository_link
      data["repository_link"]
    end

    def entries
      data.fetch("entries", [])
    end

    def latest_entry
      entries.first
    end

    def ignore_rules
      config = data.fetch("release_agent", {})
      rules = config.fetch("ignore_commits", [])
      rules.map do |rule|
        {
          "author" => compile_regex(rule["author"]),
          "email" => compile_regex(rule["email"]),
          "message" => compile_regex(rule["message"])
        }
      end
    end

    def ignored?(commit)
      ignore_rules.any? do |rule|
        matches?(rule["author"], commit.author_name) &&
          matches?(rule["email"], commit.author_email) &&
          matches?(rule["message"], commit.message)
      end
    end

    def add_entry(entry)
      data["entries"] = [entry] + entries
      write!
    end

    private

    def compile_regex(pattern)
      return nil if pattern.nil? || pattern.empty?

      Regexp.new(pattern, Regexp::IGNORECASE)
    end

    def matches?(pattern, value)
      return true if pattern.nil?

      !!(value.to_s =~ pattern)
    end

    def write!
      @path.write(serialize(data))
    end

    def serialize(payload)
      document = {
        "repository_link" => payload["repository_link"],
        "title" => payload["title"],
        "description" => payload["description"]
      }
      document["markdown_preamble"] = payload["markdown_preamble"] if payload.key?("markdown_preamble")
      document["release_agent"] = normalize_release_agent(payload["release_agent"]) if payload.key?("release_agent")
      document["entries"] = normalize_entries(payload.fetch("entries", []))

      yaml = Psych.dump(document, nil, line_width: -1).sub(/\A---\s*\n/, "")
      yaml.end_with?("\n") ? yaml : "#{yaml}\n"
    end

    def normalize_release_agent(config)
      {
        "ignore_commits" => Array(config&.fetch("ignore_commits", [])).map do |rule|
          normalized_rule = {}
          %w[author email message].each do |key|
            normalized_rule[key] = rule[key] if rule.key?(key)
          end
          normalized_rule
        end
      }
    end

    def normalize_entries(entries)
      entries.map do |entry|
        normalized_entry = {
          "version" => entry.fetch("version"),
          "release_date" => entry.fetch("release_date")
        }
        normalized_entry["notes"] = entry["notes"] if entry.key?("notes") && !entry["notes"].nil?
        normalized_entry["sections"] = ordered_sections(entry.fetch("sections", [])).map do |section|
          {
            "name" => section.fetch("name"),
            "items" => section.fetch("items", []).map do |item|
              normalized_item = {
                "text" => item.fetch("text"),
                "authors" => Array(item["authors"])
              }
              normalized_item["issue_number"] = item["issue_number"] if item.key?("issue_number")
              normalized_item["issue_marker"] = item["issue_marker"] if item.key?("issue_marker") && item["issue_marker"] != "#"
              normalized_item
            end
          }
        end
        normalized_entry
      end
    end

    def ordered_sections(sections)
      sections.sort_by do |section|
        index = SECTION_ORDER.index(section["name"])
        index.nil? ? SECTION_ORDER.length : index
      end
    end
  end

  class ReleaseManager
    RELEASE_EVENT = "release".freeze
    PUSH_EVENT = "push".freeze

    def initialize(options)
      @options = options
      @logger = Logger.new
      @shell = Shell.new(logger: @logger, dry_run: options[:dry_run])
      @repo_path = Pathname(options[:repo]).expand_path
      @changelog_path = resolve_changelog_path
      @info_xml_path = @repo_path.join("appinfo", "info.xml")
      @markdown_path = resolve_markdown_path
      @changelog = ChangelogFile.new(@changelog_path)
      @origin_remote = options[:remote]
      @release_remote = options[:release_remote]
      @release_remote_exists = remote_exists?(@release_remote)
      @logger.warn("release remote '#{@release_remote}' not found: skipping release remote steps") unless @release_remote_exists
    end

    def prepare
      with_release_context do |context|
        branch_name = "#{@options[:branch_prefix]}#{context[:version]}"
        create_or_reset_branch(branch_name, context[:default_branch])
        update_metadata_files(context)
        commit_paths = [relative_path(@changelog_path), relative_path(@markdown_path), relative_path(@info_xml_path)]
        commit_release(branch_name, context[:version], commit_paths)
        push_branch(branch_name)
        pr = create_pull_request(branch_name, context[:default_branch], context[:version], context[:release_notes])
        @logger.status("prepared release #{context[:version]} on #{branch_name}")
        @logger.info("pull request: #{pr.fetch('url')}")
        { version: context[:version], branch: branch_name, pr: pr }
      end
    end

    def publish(version = nil, pr: nil)
      version ||= latest_version
      default_branch = ensure_default_branch_name
      pr ||= find_release_pull_request(version)
      raise Error, "could not find release PR for #{version}" if pr.nil?

      ensure_pull_request_merged(pr.fetch("number"), version)
      sync_default_branch(default_branch)
      tag_name = "v#{version}"
      create_and_push_tag(tag_name)
      release_notes = render_release_notes(version)
      create_github_release(@origin_remote, tag_name, version, release_notes)
      create_github_release(@release_remote, tag_name, version, release_notes) if @release_remote_exists
      monitor(version) if @options[:monitor]
      { version: version, pr: pr, tag: tag_name }
    end

    def run
      prepared = prepare
      publish(prepared.fetch(:version), pr: prepared.fetch(:pr))
    end

    def monitor(version = nil)
      version ||= latest_version
      commit_sha = git("rev-parse", "HEAD").stdout.strip
      tag_name = "v#{version}"
      @logger.status("monitoring workflow runs for #{tag_name}")
      monitor_repo_runs(@origin_remote, PUSH_EVENT, commit_sha, version)
      monitor_repo_runs(@release_remote, RELEASE_EVENT, commit_sha, version) if @release_remote_exists
    end

    private

    def with_release_context
      validate_repo!
      default_branch = ensure_default_branch_name
      ensure_clean_worktree! unless @options[:allow_dirty]
      sync_default_branch(default_branch)
      commits = collect_commits
      raise Error, "no releasable commits found since the last tag" if commits.empty?

      enriched_commits = enrich_commits(commits)
      filtered_commits = enriched_commits.reject do |commit|
        ignored = @changelog.ignored?(commit)
        @logger.info("ignoring #{commit.sha[0, 7]} #{commit.message.inspect}") if ignored
        ignored
      end
      raise Error, "all commits were ignored by changelog release_agent.ignore_commits" if filtered_commits.empty?

      classify_commits!(filtered_commits)
      version = bump_version(filtered_commits)
      release_notes_entry = build_changelog_entry(version, filtered_commits)
      release_notes = render_release_notes_for_entry(release_notes_entry)
      yield(
        version: version,
        default_branch: default_branch,
        commits: filtered_commits,
        changelog_entry: release_notes_entry,
        release_notes: release_notes
      )
    end

    def validate_repo!
      raise Error, "repo path does not exist: #{@repo_path}" unless @repo_path.directory?
      raise Error, "missing changelog file: #{@changelog_path}" unless @changelog_path.file?
      raise Error, "missing info.xml: #{@info_xml_path}" unless @info_xml_path.file?
    end

    def resolve_changelog_path
      configured = @options[:changelog] && Pathname(@options[:changelog])
      return configured.expand_path if configured

      [@repo_path.join("changelog.yaml"), @repo_path.join("CHANGELOG.yaml")].find(&:file?) || @repo_path.join("changelog.yaml")
    end

    def resolve_markdown_path
      configured = @options[:markdown] && Pathname(@options[:markdown])
      return configured.expand_path if configured

      [@repo_path.join("CHANGELOG.md"), @repo_path.join("changelog.md"), @repo_path.join("changelog.generated.md")].find(&:file?) || @repo_path.join("CHANGELOG.md")
    end

    def ensure_clean_worktree!
      status = git("status", "--porcelain").stdout
      return if status.strip.empty?

      raise Error, "working tree is dirty; rerun with --allow-dirty to bypass"
    end

    def ensure_default_branch_name
      return @options[:default_branch] if @options[:default_branch]

      remote_head = git("symbolic-ref", "refs/remotes/#{@origin_remote}/HEAD", allow_failure: true)
      if remote_head.status.zero?
        return remote_head.stdout.strip.split("/").last
      end

      repo = remote_repo_slug(@origin_remote)
      response = gh_json("repo", "view", "--repo", repo, "--json", "defaultBranchRef")
      response.fetch("defaultBranchRef").fetch("name")
    end

    def sync_default_branch(default_branch)
      @logger.status("syncing #{default_branch}")
      git("fetch", "--all", "--tags", "--prune")
      current_branch = git("branch", "--show-current").stdout.strip
      git("checkout", default_branch) unless current_branch == default_branch
      git("pull", "--ff-only", @origin_remote, default_branch)
    end

    def create_or_reset_branch(branch_name, default_branch)
      @logger.status("creating branch #{branch_name}")
      git("checkout", "-B", branch_name, default_branch)
    end

    def collect_commits
      @logger.status("collecting commits since last tag")
      last_tag = git("describe", "--tags", "--abbrev=0", "--match", "v*", "HEAD", allow_failure: true)
      range = last_tag.status.zero? ? "#{last_tag.stdout.strip}..HEAD" : "HEAD"
      format = "%H%x1f%an%x1f%ae%x1f%s"
      output = git("log", "--reverse", "--format=#{format}", range).stdout
      output.lines.filter_map do |line|
        sha, author_name, author_email, message = line.chomp.split("\u001F", 4)
        next if sha.nil? || sha.empty?

        CommitInfo.new(
          sha: sha,
          author_name: author_name,
          author_email: author_email,
          message: message,
          labels: []
        )
      end
    end

    def enrich_commits(commits)
      repo = remote_repo_slug(@origin_remote)
      commits.each do |commit|
        pulls = gh_api_json("repos/#{repo}/commits/#{commit.sha}/pulls", repo: repo, default: [])
        pull = Array(pulls).first
        next unless pull

        detail = gh_api_json("repos/#{repo}/pulls/#{pull.fetch('number')}", repo: repo)
        commit.pr_number = detail.fetch("number")
        commit.pr_title = detail.fetch("title")
        commit.pr_body = detail["body"].to_s
        commit.pr_url = detail.fetch("html_url")
        commit.pr_author = detail.fetch("user", {}).fetch("login", nil)
        commit.labels = Array(detail["labels"]).map { |label| label.fetch("name") }
      end
      commits
    end

    def classify_commits!(commits)
      commits.each do |commit|
        text = [commit.pr_title, commit.pr_body, commit.message].compact.join("\n")
        labels = commit.labels.map(&:downcase)
        commit.classification = if breaking_change?(text, labels)
          :breaking
        elsif feature_change?(text, labels)
          :feature
        elsif fix_change?(text, labels)
          :fix
        else
          :change
        end

        commit.section = case commit.classification
        when :feature
          "Added"
        when :fix
          "Fixed"
        else
          "Changed"
        end
      end
    end

    def breaking_change?(text, labels)
      return true if labels.any? { |label| label.include?("breaking") || label == "major" }

      !!(text =~ /BREAKING CHANGE|!:/i)
    end

    def feature_change?(text, labels)
      return true if labels.any? { |label| %w[feature enhancement added minor].include?(label) || label.include?("feature") }

      !!(text =~ /(^|\n)feat(?:\([^)]+\))?!?:|(^|\n)add(ed)?\b|(^|\n)feature\b|(^|\n)enh\b/i)
    end

    def fix_change?(text, labels)
      return true if labels.any? { |label| %w[fix bug bugfix security regression patch].include?(label) || label.include?("bug") }

      !!(text =~ /(^|\n)fix(?:\([^)]+\))?!?:|(^|\n)bug|(^|\n)security\b/i)
    end

    def bump_version(commits)
      current = parse_version(@changelog.latest_entry&.fetch("version", nil) || current_info_xml_version)
      next_parts = current.dup

      if commits.any? { |commit| commit.classification == :breaking }
        next_parts[0] += 1
        next_parts[1] = 0
        next_parts[2] = 0
      elsif commits.any? { |commit| commit.classification == :feature }
        next_parts[1] += 1
        next_parts[2] = 0
      else
        next_parts[2] += 1
      end

      next_parts.join(".")
    end

    def parse_version(version)
      match = version.to_s.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
      raise Error, "unsupported semver version: #{version.inspect}" unless match

      match.captures.map(&:to_i)
    end

    def current_info_xml_version
      xml = REXML::Document.new(@info_xml_path.read)
      REXML::XPath.first(xml, "//info/version/text()").to_s
    end

    def build_changelog_entry(version, commits)
      grouped = commits.group_by(&:section)
      sections = ChangelogFile::SECTION_ORDER.filter_map do |section_name|
        items = Array(grouped[section_name]).map { |commit| build_changelog_item(commit) }
        next if items.empty?

        { "name" => section_name, "items" => items }
      end

      {
        "version" => version,
        "release_date" => Date.today.iso8601,
        "sections" => sections
      }
    end

    def build_changelog_item(commit)
      text = clean_summary(commit.pr_title || commit.message)
      text = "BREAKING: #{text}" if commit.classification == :breaking && !text.start_with?("BREAKING:")

      item = {
        "text" => text,
        "authors" => normalize_authors(commit)
      }
      item["issue_number"] = commit.pr_number unless commit.pr_number.nil?
      item
    end

    def clean_summary(text)
      text.to_s
        .sub(/\A(?:feat|fix|chore|docs|refactor|test|ci|build)(?:\([^)]+\))?!?:\s*/i, "")
        .sub(/\Amerge pull request\s+#\d+.*?\n?/i, "")
        .strip
    end

    def normalize_authors(commit)
      candidate = commit.pr_author || commit.author_name
      return [] if candidate.nil?

      sanitized = candidate.strip.gsub(/\s+/, "-")
      sanitized.match?(/\A[0-9A-Za-z][0-9A-Za-z-]*\z/) ? [sanitized] : []
    end

    def update_metadata_files(context)
      @logger.status("updating changelog and app metadata")
      @changelog.add_entry(context.fetch(:changelog_entry))
      render_markdown_changelog
      update_info_xml(context.fetch(:version))
    end

    def render_markdown_changelog
      @markdown_path.dirname.mkpath
      data = Psych.safe_load(@changelog_path.read, aliases: false, permitted_classes: [], symbolize_names: false) || {}
      renderer = ChangelogRenderer.new(data["repository_link"])
      @markdown_path.write(renderer.render_document(data, data.fetch("entries", [])))
    end

    def render_release_notes(version)
      data = Psych.safe_load(@changelog_path.read, aliases: false, permitted_classes: [], symbolize_names: false) || {}
      renderer = ChangelogRenderer.new(data["repository_link"])
      entry = data.fetch("entries", []).find { |e| e.fetch("version") == version }
      raise Error, "no changelog entry found for version #{version}" unless entry

      renderer.render_entry(entry)
    end

    def render_release_notes_for_entry(entry)
      renderer = ChangelogRenderer.new(@changelog.repository_link)
      renderer.render_entry(entry)
    end

    def update_info_xml(version)
      xml_text = @info_xml_path.read
      updated = xml_text.sub(%r{<version>.*?</version>}, "<version>#{version}</version>")
      updated = updated.sub(%r{<image-tag>.*?</image-tag>}, "<image-tag>#{version}</image-tag>") if updated.include?("<image-tag>")
      @info_xml_path.write(updated)
    end

    def commit_release(branch_name, version, paths)
      @logger.status("committing release #{version}")
      paths.each { |path| git("add", path) }
      git("commit", "-s", "-m", version)
    rescue Error => error
      raise unless error.message.include?("nothing to commit")

      @logger.warn("no content changes were staged for #{branch_name}")
    end

    def push_branch(branch_name)
      return if @options[:no_push]

      @logger.status("pushing #{branch_name} to #{@origin_remote}")
      git("push", "--set-upstream", @origin_remote, branch_name)
      pause_for_visibility("waiting for #{branch_name} to be visible on GitHub")
    end

    def create_pull_request(branch_name, default_branch, version, release_notes)
      repo = remote_repo_slug(@origin_remote)
      body_file = Tempfile.new(["release-notes", ".md"])
      body_file.write(release_notes)
      body_file.flush
      create_result = gh(
        "pr",
        "create",
        "--repo",
        repo,
        "--base",
        default_branch,
        "--head",
        branch_name,
        "--title",
        version,
        "--body-file",
        body_file.path,
      )
      pr_url = extract_pull_request_url(create_result.stdout)
      raise Error, "could not determine created pull request URL" if pr_url.nil?

      wait_for_release_pull_request(repo, version, branch_name, pr_url: pr_url)
    ensure
      body_file&.close!
    end

    def extract_pull_request_url(text)
      text.to_s.lines.reverse_each do |line|
        match = line.match(%r{https://github\.com/[^\s]+/pull/\d+})
        return match[0] if match
      end

      nil
    end

    def latest_version
      @changelog.latest_entry&.fetch("version") || current_info_xml_version
    end

    def find_release_pull_request(version)
      repo = remote_repo_slug(@origin_remote)
      wait_for_release_pull_request(repo, version, "#{@options[:branch_prefix]}#{version}")
    end

    def ensure_pull_request_merged(pr_number, version)
      repo = remote_repo_slug(@origin_remote)
      begin
        @logger.status("merging PR ##{pr_number} for #{version}")
        gh("pr", "merge", pr_number.to_s, "--repo", repo, "--squash", "--admin")
      rescue Error => error
        @logger.warn("automatic merge failed: #{error.message.lines.first.strip}")
        @logger.warn("waiting for the PR to be merged manually")
      end

      wait_for_merge(repo, pr_number)
    end

    def wait_for_merge(repo, pr_number)
      deadline = Time.now + @options[:poll_timeout]
      loop do
        pr = gh_json("pr", "view", pr_number.to_s, "--repo", repo, "--json", "number,state,mergedAt,url")
        return pr if pr["mergedAt"]

        if pr["state"] == "CLOSED"
          raise Error, "PR #{pr.fetch('url')} was closed without merging"
        end

        raise Error, "timed out waiting for #{pr.fetch('url')} to merge" if Time.now >= deadline

        @logger.info("PR not merged yet, sleeping #{@options[:poll_interval]}s")
        sleep(@options[:poll_interval]) unless @options[:dry_run]
      end
    end

    def create_and_push_tag(tag_name)
      @logger.status("tagging #{tag_name}")
      git("tag", tag_name)
      git("push", @origin_remote, tag_name)
      git("push", @release_remote, tag_name) if @release_remote_exists
      pause_for_visibility("waiting for #{tag_name} to be visible on GitHub")
    end

    def create_github_release(remote_name, tag_name, version, release_notes)
      repo = remote_repo_slug(remote_name)
      @logger.status("creating GitHub release #{version} in #{remote_name}")
      notes_file = Tempfile.new(["release-notes", ".md"])
      begin
        notes_file.write(release_notes)
        notes_file.flush
        gh("release", "create", tag_name, "--repo", repo, "--title", version, "--notes-file", notes_file.path, "--verify-tag")
      ensure
        notes_file.close!
      end
    end

    def wait_for_release_pull_request(repo, version, branch_name, pr_url: nil)
      deadline = Time.now + @options[:poll_timeout]

      loop do
        if pr_url
          view_result = gh("pr", "view", pr_url, "--repo", repo, "--json", "number,url,title,state,mergedAt,headRefName", allow_failure: true)
          return JSON.parse(view_result.stdout) if view_result.status.zero?
        end

        pr = query_release_pull_request(repo, version, branch_name)
        return pr if pr

        raise Error, "could not find release PR for #{version}" if Time.now >= deadline

        pause_for_visibility("waiting for release PR #{version} to become visible")
      end
    end

    def query_release_pull_request(repo, version, branch_name)
      prs = gh_json("pr", "list", "--repo", repo, "--state", "all", "--search", version, "--json", "number,title,url,state,mergedAt,headRefName")
      Array(prs).find { |pr| pr["title"] == version || pr["headRefName"] == branch_name }
    end

    def pause_for_visibility(message)
      @logger.info("#{message}; sleeping #{@options[:poll_interval]}s")
      sleep(@options[:poll_interval]) unless @options[:dry_run]
    end

    def monitor_repo_runs(remote_name, event, commit_sha, version)
      repo = remote_repo_slug(remote_name)
      deadline = Time.now + @options[:poll_timeout]
      matching_run = nil

      loop do
        runs = gh_api_json("repos/#{repo}/actions/runs?event=#{event}&per_page=20", repo: repo, default: {}).fetch("workflow_runs", [])
        matching_run = runs.find do |run|
          run.fetch("head_sha", "") == commit_sha || run.fetch("display_title", "").include?(version)
        end

        break if matching_run || Time.now >= deadline

        @logger.info("waiting for #{remote_name} #{event} workflow run")
        sleep(@options[:poll_interval]) unless @options[:dry_run]
      end

      unless matching_run
        @logger.warn("no matching #{event} workflow run found in #{remote_name}")
        return
      end

      loop do
        run = gh_api_json("repos/#{repo}/actions/runs/#{matching_run.fetch('id')}", repo: repo)
        status = run.fetch("status")
        conclusion = run["conclusion"]
        if status == "completed"
          if conclusion == "success"
            @logger.info("workflow succeeded: #{run.fetch('html_url')}")
          else
            @logger.warn("workflow #{conclusion || 'failed'}: #{run.fetch('html_url')}")
          end
          return
        end

        raise Error, "timed out waiting for workflow #{run.fetch('html_url')}" if Time.now >= deadline

        @logger.info("workflow #{run.fetch('name')} is #{status}; sleeping #{@options[:poll_interval]}s")
        sleep(@options[:poll_interval]) unless @options[:dry_run]
      end
    end

    def relative_path(path)
      Pathname(path).relative_path_from(@repo_path).to_s
    end

    def remote_exists?(remote_name)
      result = git("remote", "get-url", remote_name, allow_failure: true)
      result.status.zero?
    end

    def remote_repo_slug(remote_name)
      url = git("remote", "get-url", remote_name).stdout.strip
      match = url.match(%r{github\.com[:/](.+?)(?:\.git)?\z})
      raise Error, "unsupported GitHub remote URL for #{remote_name}: #{url}" unless match

      match[1]
    end

    def gh_api_json(path, repo:, default: nil)
      result = gh("api", path, "-H", "Accept: application/vnd.github+json", allow_failure: !default.nil?)
      return default if !default.nil? && result.status != 0

      JSON.parse(result.stdout)
    end

    def gh_json(*args)
      result = gh(*args)
      JSON.parse(result.stdout)
    end

    def git(*args, allow_failure: false)
      @shell.capture("git", *args, chdir: @repo_path.to_s, allow_failure: allow_failure)
    end

    def gh(*args, allow_failure: false)
      @shell.capture("gh", *args, chdir: @repo_path.to_s, allow_failure: allow_failure)
    end
  end

  class CLI
    SUBCOMMANDS = %w[prepare publish run monitor].freeze

    def initialize(argv)
      @argv = argv.dup
    end

    def run
      subcommand = @argv.shift
      return usage if subcommand.nil? || %w[-h --help help].include?(subcommand)
      raise Error, "unknown subcommand: #{subcommand}" unless SUBCOMMANDS.include?(subcommand)

      options = default_options
      parser = option_parser(options)
      parser.parse!(@argv)

      manager = ReleaseManager.new(options)
      case subcommand
      when "prepare"
        manager.prepare
      when "publish"
        manager.publish(@argv.shift)
      when "run"
        manager.run
      when "monitor"
        manager.monitor(@argv.shift)
      end
      0
    rescue Error, OptionParser::ParseError => error
      $stderr.puts("[ERROR] #{error.message}")
      1
    end

    private

    def usage
      puts(option_parser(default_options))
      0
    end

    def default_options
      {
        repo: Dir.pwd,
        changelog: nil,
        markdown: nil,
        remote: "origin",
        release_remote: "release",
        default_branch: nil,
        branch_prefix: "release/",
        dry_run: false,
        no_push: false,
        allow_dirty: false,
        monitor: false,
        poll_interval: 15,
        poll_timeout: 1800
      }
    end

    def option_parser(options)
      OptionParser.new do |parser|
        parser.banner = <<~TEXT
          Usage: nextcloud-release-agent <prepare|publish|run|monitor> [options] [version]

          Commands:
            prepare   Update changelog and appinfo, create a release branch, push it, and open a PR.
            publish   Merge the PR if possible, tag the merge commit, push tags, create releases, and optionally monitor workflows.
            run       Execute prepare and publish in one pass.
            monitor   Watch GitHub Actions runs related to the given or latest version.
        TEXT

        parser.on("--repo PATH", "Target app repository") { |value| options[:repo] = value }
        parser.on("--changelog PATH", "Path to changelog.yaml inside the target repo") { |value| options[:changelog] = value }
        parser.on("--markdown PATH", "Path to rendered changelog markdown inside the target repo") { |value| options[:markdown] = value }
        parser.on("--remote NAME", "Git remote used for the development repository (default: origin)") { |value| options[:remote] = value }
        parser.on("--release-remote NAME", "Git remote used for the release repository (default: release)") { |value| options[:release_remote] = value }
        parser.on("--default-branch NAME", "Override default branch detection") { |value| options[:default_branch] = value }
        parser.on("--branch-prefix PREFIX", "Release branch prefix (default: release/)") { |value| options[:branch_prefix] = value }
        parser.on("--allow-dirty", "Allow running with a dirty worktree") { options[:allow_dirty] = true }
        parser.on("--no-push", "Skip pushing the release branch during prepare") { options[:no_push] = true }
        parser.on("--monitor", "Monitor workflow runs after publish") { options[:monitor] = true }
        parser.on("--poll-interval SECONDS", Integer, "Polling interval for PR and workflow checks") { |value| options[:poll_interval] = value }
        parser.on("--poll-timeout SECONDS", Integer, "Maximum wait time for merge and workflow checks") { |value| options[:poll_timeout] = value }
        parser.on("--dry-run", "Print commands without mutating the target repository") { options[:dry_run] = true }
        parser.on("-h", "--help", "Show help") do
          puts(parser)
          exit(0)
        end
      end
    end
  end
end
