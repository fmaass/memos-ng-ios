# frozen_string_literal: true

# MEMNG-173: which store a release's dSYMs are written to.
#
# Pure so the "no store at all" branch is provable without unmounting anything -- a silent skip
# is exactly the defect being closed here: builds 7, 8 and 9 shipped with no preserved symbols
# because nothing copied them and nothing complained.
module DsymStore
  # candidates - ordered [[name, root], ...]; the first entry is the primary store.
  # The block answers "is this root usable right now?" and is passed in so this stays pure.
  #
  # Returns [:primary | :fallback | :none, root_or_nil, message].
  def self.choose(candidates, &reachable)
    candidates.each_with_index do |(name, root), index|
      next unless reachable.call(root)
      return [:primary, root, "dSYM store: #{name} (#{root})"] if index.zero?

      primary = candidates.first && candidates.first.first
      return [:fallback, root, "WARN: primary dSYM store #{primary} is unreachable - falling back " \
                               "to #{name} (#{root}); mirror them to #{primary} once it is back"]
    end

    tried = candidates.map { |name, root| "#{name} #{root}" }.join(", ")
    [:none, nil, "no dSYM store is reachable (tried #{tried}) - the symbols for this build would be lost"]
  end
end
