#
# shorts-filter: the "don't recommend" set, as a plain value type.
#
# Deliberately separate from Invidious::Database::NotRecommended (which owns
# the SQL): the consumers of this are ranking and rendering code —
# rank_discover in particular is pure by design, testable without a live DB
# or network — so they shouldn't have to drag the database layer in just to
# name the type of their argument.
#
module Invidious::NotRecommended
  # Sets rather than arrays because every consumer does membership tests per
  # candidate, once for the video id and once for the channel.
  record Blocked, videos : Set(String), channels : Set(String) do
    def empty? : Bool
      videos.empty? && channels.empty?
    end

    def blocks?(video_id : String?, ucid : String?) : Bool
      return true if video_id && videos.includes?(video_id)
      return true if ucid && channels.includes?(ucid)
      false
    end
  end

  EMPTY = Blocked.new(Set(String).new, Set(String).new)
end
