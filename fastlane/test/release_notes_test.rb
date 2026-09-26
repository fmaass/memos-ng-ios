# frozen_string_literal: true

# Run: ruby -Ifastlane/lib fastlane/test/release_notes_test.rb
require "minitest/autorun"
require "release_notes"

class ReleaseNotesTest < Minitest::Test
  NOTES = <<~MARKDOWN
    # TestFlight notes

    Anything above the first release heading is ignored.

    ## 1.5.6 (25)

    - Newest entry.

    ### A subheading stays inside its section

    - Still 25.

    ## 1.5.5 (24)

    - Whole-file uploads.
    - A second line.

    ## 1.5.4 (23)

    - Oldest entry.
  MARKDOWN

  def section(text, version: "1.5.5", build: "24")
    ReleaseNotes.section(text, version: version, build: build)
  end

  def assert_refused(result, pattern)
    status, message = result
    assert_equal(:refuse, status, "expected a refusal, got #{result.inspect}")
    assert_match(pattern, message)
  end

  def test_the_matching_section_is_returned_without_its_heading_or_neighbours
    assert_equal([:ok, "- Whole-file uploads.\n- A second line."], section(NOTES))
  end

  def test_the_last_section_runs_to_the_end_of_the_file
    assert_equal([:ok, "- Oldest entry."], section(NOTES, version: "1.5.4", build: "23"))
  end

  def test_a_deeper_heading_stays_inside_its_section
    status, notes = section(NOTES, version: "1.5.6", build: "25")
    assert_equal(:ok, status)
    assert_equal("- Newest entry.\n\n### A subheading stays inside its section\n\n- Still 25.", notes)
  end

  def test_an_absent_section_is_refused_and_names_what_was_looked_for
    assert_refused(section(NOTES, version: "2.0.0", build: "26"), /no section "## 2\.0\.0 \(26\)"/)
  end

  def test_an_empty_section_is_refused
    text = "## 1.5.5 (24)\n## 1.5.4 (23)\n\n- Oldest.\n"
    assert_refused(section(text), /section "## 1\.5\.5 \(24\)" is empty/)
  end

  def test_a_whitespace_only_section_is_refused
    text = "## 1.5.5 (24)\n\n   \n\t\n## 1.5.4 (23)\n- Oldest.\n"
    assert_refused(section(text), /is empty/)
  end

  def test_an_empty_last_section_is_refused
    assert_refused(section("## 1.5.5 (24)\n\n"), /is empty/)
  end

  def test_an_empty_file_is_refused
    assert_refused(section(""), /no section/)
  end

  def test_a_neighbouring_version_or_build_is_not_taken_for_this_one
    text = "## 1.5.55 (24)\n- a\n## 11.5.5 (24)\n- b\n## 1.5.5 (245)\n- c\n## 1.5.5 (2)\n- d\n" \
           "## 1.5.5 (24) hotfix\n- e\n### 1.5.5 (24)\n- f\n"
    assert_refused(section(text), /no section/)
  end

  def test_a_dot_in_the_version_is_literal
    assert_refused(section("## 1x5x5 (24)\n- a\n"), /no section/)
  end

  def test_a_heading_inside_a_code_fence_is_not_a_section
    text = "## 1.5.4 (23)\n\n```\n## 1.5.5 (24)\n- fenced\n```\n"
    assert_refused(section(text), /no section/)
  end

  def test_a_heading_inside_a_code_fence_does_not_end_a_section
    text = "## 1.5.5 (24)\n\n~~~\n## 1.5.4 (23)\n~~~\n- after\n"
    assert_equal([:ok, "~~~\n## 1.5.4 (23)\n~~~\n- after"], section(text))
  end

  def test_a_duplicated_section_is_refused_as_ambiguous
    text = "## 1.5.5 (24)\n- a\n## 1.5.5 (24)\n- b\n"
    assert_refused(section(text), /2 sections "## 1\.5\.5 \(24\)"/)
  end

  def test_trailing_whitespace_and_crlf_on_the_heading_are_tolerated
    assert_equal([:ok, "- a"], section("## 1.5.5 (24)  \r\n- a\r\n"))
  end

  def test_a_blank_version_or_build_is_refused_before_the_file_is_searched
    assert_refused(section(NOTES, version: "", build: "24"), /version and build/)
    assert_refused(section(NOTES, version: "1.5.5", build: "  "), /version and build/)
    assert_refused(section(NOTES, version: nil, build: "24"), /version and build/)
  end

  def test_notes_at_the_testflight_limit_are_kept_and_one_past_it_is_refused
    at_limit = "x" * ReleaseNotes::MAX_CHARACTERS
    assert_equal([:ok, at_limit], section("## 1.5.5 (24)\n#{at_limit}\n"))
    assert_refused(section("## 1.5.5 (24)\n#{at_limit}x\n"), /4001 characters/)
  end

  def test_an_absent_file_is_refused_and_named
    missing = File.join(__dir__, "no-such-notes-file.md")
    assert_refused(ReleaseNotes.load(missing, version: "1.5.5", build: "24"),
                   /no-such-notes-file\.md/)
  end

  def test_the_tracked_file_carries_the_notes_for_build_24
    tracked = File.expand_path("../TESTFLIGHT_NOTES.md", __dir__)
    status, notes = ReleaseNotes.load(tracked, version: "1.5.5", build: "24")
    assert_equal(:ok, status, notes)
    refute_empty(notes)
  end
end
