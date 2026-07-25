require "./base.cr"

#
# shorts-filter: per-user "don't recommend this" list.
#
# Lets a user suppress a specific video, or everything from a creator, so it
# stops showing up in the Discover feed and in related-video lists. Stock
# Invidious has no equivalent — the only way to influence recommendations is
# to subscribe/unsubscribe, which is a blunt instrument for "I never want to
# see this channel suggested again".
#
# Videos and channels share one table, discriminated by `kind`, since every
# read path wants both sets at once (filtering a candidate means checking its
# id *and* its ucid) and a single query is cheaper than two.
#
module Invidious::Database::NotRecommended
  extend self

  enum Kind
    Video
    Channel

    def to_db : String
      self.to_s.downcase
    end
  end

  # Both blocked sets for a user, fetched in one round-trip. Returned as Sets
  # because the callers (Discover ranking, related-video filtering) do
  # membership tests per candidate.
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

  def select_all(user : User) : Blocked
    request = <<-SQL
      SELECT kind, target_id FROM not_recommended
      WHERE email = $1
    SQL

    videos = Set(String).new
    channels = Set(String).new

    PG_DB.query_all(request, user.email, as: {String, String}).each do |(kind, target_id)|
      case kind
      when Kind::Video.to_db   then videos << target_id
      when Kind::Channel.to_db then channels << target_id
      end
    end

    Blocked.new(videos, channels)
  end

  # Convenience for request paths that only have an optional user (e.g. the
  # watch page, where the visitor may be logged out).
  def select_all?(user : User?) : Blocked
    return EMPTY if user.nil?
    select_all(user)
  end

  def insert(user : User, kind : Kind, target_id : String)
    request = <<-SQL
      INSERT INTO not_recommended (email, kind, target_id, created)
      VALUES ($1, $2, $3, now())
      ON CONFLICT (email, kind, target_id) DO NOTHING
    SQL

    PG_DB.exec(request, user.email, kind.to_db, target_id)
  end

  def delete(user : User, kind : Kind, target_id : String)
    request = <<-SQL
      DELETE FROM not_recommended
      WHERE email = $1 AND kind = $2 AND target_id = $3
    SQL

    PG_DB.exec(request, user.email, kind.to_db, target_id)
  end

  def clear(user : User)
    request = <<-SQL
      DELETE FROM not_recommended
      WHERE email = $1
    SQL

    PG_DB.exec(request, user.email)
  end
end
