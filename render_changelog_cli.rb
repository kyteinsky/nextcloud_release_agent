#!/usr/bin/env ruby

require "yaml"

USAGE = <<~TEXT
  Usage:
    render_changelog.rb render [input_path] [output_path]
      Write the full changelog markdown to output_path.
    render_changelog.rb latest [input_path]
      Write only the latest changelog entry to stdout.
    render_changelog.rb version <version> [input_path]
      Write only the requested changelog entry to stdout.
    render_changelog.rb help
      Show this help text.

  Examples:
    render_changelog.rb render changelog.yaml changelog.generated.md
    render_changelog.rb latest changelog.yaml
    render_changelog.rb version 2.3.0 changelog.yaml

  Notes:
    - Uses repository_link to render issue numbers as markdown links when available.
TEXT

def usage_error
  warn USAGE
  exit 1
end

def format_item(item, repository_link)
  text = item.fetch("text")
  issue_number = item["issue_number"]
  issue_marker = item.fetch("issue_marker", "#")
  authors = item.fetch("authors", [])

  rendered = text.dup
  unless issue_number.nil?
    if repository_link && !repository_link.empty?
      rendered << " ([#{issue_marker}#{issue_number}](#{repository_link}/pull/#{issue_number}))"
    else
      rendered << " (#{issue_marker}#{issue_number})"
    end
  end
  rendered << authors.map { |author| " @#{author}" }.join unless authors.empty?
  rendered
end

def render_entry(entry, repository_link)
  lines = []
  lines << "## #{entry.fetch("version")} - #{entry.fetch("release_date")}"

  notes = entry["notes"]
  if notes && !notes.empty?
    lines << ""
    lines.concat(notes.split("\n"))
  end

  entry.fetch("sections", []).each do |section|
    lines << "" unless lines.last == ""
    lines << "### #{section.fetch("name")}"
    section.fetch("items", []).each do |item|
      lines << "- #{format_item(item, repository_link)}"
    end
  end

  lines.join("\n")
end

def load_changelog(input_path)
  unless File.file?(input_path)
    abort("Input changelog file not found: #{input_path}")
  end

  data = YAML.safe_load(File.read(input_path), permitted_classes: [], aliases: false)
  repository_link = data["repository_link"]&.sub(%r{/$}, "")

  [data, repository_link, data.fetch("entries")]
end

def render_document(data, repository_link, entries)
  preamble = data["markdown_preamble"]
  document_lines = []
  if preamble && !preamble.empty?
    document_lines << preamble.rstrip
  end

  entry_separator = "\n\n\n"
  rendered_entries = entries.map { |entry| render_entry(entry, repository_link) }

  if document_lines.empty?
    rendered_entries.join(entry_separator) + "\n"
  else
    document_lines.join("\n") + "\n\n" + rendered_entries.join(entry_separator) + "\n"
  end
end

arguments = ARGV.dup

if arguments.empty? || arguments.include?("--help") || arguments.include?("-h") || arguments.first == "help"
  puts USAGE
  exit 0
end

subcommand = arguments.shift

case subcommand
when "render"
  usage_error if arguments.length > 2

  input_path = arguments[0] || "changelog.yaml"
  output_path = arguments[1] || "changelog.generated.md"
  data, repository_link, entries = load_changelog(input_path)
  document = render_document(data, repository_link, entries)
  File.write(output_path, document)
when "latest"
  usage_error if arguments.length > 1

  input_path = arguments[0] || "changelog.yaml"
  _data, repository_link, entries = load_changelog(input_path)
  latest_entry = entries.first
  abort("No changelog entries found in #{input_path}") if latest_entry.nil?

  puts render_entry(latest_entry, repository_link)
when "version"
  usage_error if arguments.empty? || arguments.length > 2

  requested_version = arguments[0]
  input_path = arguments[1] || "changelog.yaml"
  _data, repository_link, entries = load_changelog(input_path)
  entry = entries.find { |candidate| candidate.fetch("version") == requested_version }
  abort("No changelog entry found for version #{requested_version}") if entry.nil?

  puts render_entry(entry, repository_link)
else
  usage_error
end