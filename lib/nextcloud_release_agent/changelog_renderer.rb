module NextcloudReleaseAgent
  class ChangelogRenderer
    def initialize(repository_link)
      @repository_link = repository_link&.sub(%r{/$}, "")
    end

    def render_document(data, entries)
      preamble = data["markdown_preamble"]
      document_lines = []
      if preamble && !preamble.empty?
        document_lines << preamble.rstrip
      end

      rendered_entries = entries.map { |entry| render_entry(entry) }
      entry_separator = "\n\n\n"

      if document_lines.empty?
        rendered_entries.join(entry_separator) + "\n"
      else
        document_lines.join("\n") + "\n\n" + rendered_entries.join(entry_separator) + "\n"
      end
    end

    def render_entry(entry)
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
          lines << "- #{format_item(item)}"
        end
      end

      lines.join("\n")
    end

    private

    def format_item(item)
      text = item.fetch("text")
      issue_number = item["issue_number"]
      issue_marker = item.fetch("issue_marker", "#")
      authors = item.fetch("authors", [])

      rendered = text.dup
      unless issue_number.nil?
        if @repository_link && !@repository_link.empty?
          rendered << " ([#{issue_marker}#{issue_number}](#{@repository_link}/pull/#{issue_number}))"
        else
          rendered << " (#{issue_marker}#{issue_number})"
        end
      end
      rendered << authors.map { |author| " @#{author}" }.join unless authors.empty?
      rendered
    end
  end
end
