# frozen_string_literal: true

# MEMNG-571: the "What to Test" text a TestFlight upload carries, read from a tracked file.
#
# `upload_to_testflight` without `changelog:` leaves every build's notes blank, and nothing in
# the lane noticed. The notes live in
# Packages/MemosFeatures/Sources/MemosFeatures/Resources/ReleaseNotes.md — the same file the app's
# What's new screen reads (MEMNG-497) — one `## <version> (<build>)` section per build, and the
# lane asks for the section of the numbers it actually archived. A
# missing, empty, duplicated or oversized section refuses before anything is uploaded: a blank
# changelog is the defect, so it cannot be the fallback. Pure apart from `load`'s one file read.
module ReleaseNotes
  # App Store Connect's limit on a build's "What to Test" text.
  MAX_CHARACTERS = 4000

  # A fence opens on a run of three or more backticks or tildes, and (CommonMark) closes only on
  # a line that is nothing but a run of the SAME character at least as long as the opening one.
  FENCE = /\A\s*(`{3,}|~{3,})/.freeze
  # A level-1 or level-2 heading ends a section; deeper headings belong to it.
  SECTION_END = /\A\#{1,2}(\s|\z)/.freeze

  # Returns [:ok, notes] or [:refuse, message].
  def self.load(path, version:, build:)
    return [:refuse, "no release notes file at #{path}"] unless File.file?(path)

    status, detail = section(File.read(path, encoding: "UTF-8"), version: version, build: build)
    status == :ok ? [status, detail] : [status, "#{path}: #{detail}"]
  end

  # Returns [:ok, notes] or [:refuse, message].
  def self.section(text, version:, build:)
    if blank?(version) || blank?(build)
      return [:refuse, "the version and build are both needed to pick a section " \
                       "(got #{version.inspect}, #{build.inspect})"]
    end

    heading = "## #{version.to_s.strip} (#{build.to_s.strip})"
    sections = sections_titled(text.to_s, heading)
    return [:refuse, "no section #{heading.inspect}"] if sections.empty?
    return [:refuse, "#{sections.size} sections #{heading.inspect} - keep exactly one"] if sections.size > 1

    notes = sections.first.join("\n").strip
    return [:refuse, "section #{heading.inspect} is empty"] if notes.empty?
    if notes.length > MAX_CHARACTERS
      return [:refuse, "section #{heading.inspect} is #{notes.length} characters; " \
                       "TestFlight takes at most #{MAX_CHARACTERS}"]
    end

    [:ok, notes]
  end

  # A heading inside a code fence is text, so it neither opens nor closes a section.
  def self.sections_titled(text, heading)
    found = []
    current = nil
    fence = nil
    text.each_line do |raw|
      line = raw.chomp
      if fence.nil? && line.rstrip.match?(SECTION_END)
        current = line.rstrip == heading ? [] : nil
        found << current if current
        next
      end
      fence = fence_after(line, fence)
      current << line if current
    end
    found
  end
  private_class_method :sections_titled

  # The fence open after `line`: the run that opened it, or nil when none is.
  def self.fence_after(line, fence)
    return line[FENCE, 1] if fence.nil?

    closing = line.strip
    closes = closing.length >= fence.length && closing.delete(fence[0]).empty?
    closes ? nil : fence
  end
  private_class_method :fence_after

  def self.blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
  private_class_method :blank?
end
