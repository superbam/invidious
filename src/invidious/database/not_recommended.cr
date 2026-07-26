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
# The Blocked value type itself lives in Invidious::NotRecommended so that
# ranking/rendering code can name it without depending on this module.
#
module Invidious::Database::NotRecommended
  extend self

  alias Blocked = Invidious::NotRecommended::Blocked

  enum Kind
    Video
    Channel

    def to_db : String
      self.to_s.downcase
    end
  end

  # Both blocked sets for a user, fetched in one round-trip.
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
    return Invidious::NotRecommended::EMPTY if user.nil?
    select_all(user)
  end

  # One entry, for the management page. `title` is whatever label was visible
  # when the entry was created; nil for rows added before titles were stored,
  # or by an API client that didn't send one.
  record Entry, kind : Kind, target_id : String, title : String?, created : Time do
    # What to show in a list. Falls back to the raw id, which is at least
    # actionable — it's what the URL uses.
    def label : String
      t = title
      return target_id if t.nil? || t.blank?
      t
    end
  end

  def select_entries(user : User) : Array(Entry)
    request = <<-SQL
      SELECT kind, target_id, title, created FROM not_recommended
      WHERE email = $1
    SQL

    PG_DB.query_all(request, user.email, as: {String, String, String?, Time})
      .compact_map do |(kind, target_id, title, created)|
        parsed = Kind.parse?(kind)
        parsed.nil? ? nil : Entry.new(parsed, target_id, title, created)
      end
  end

  # `title` is the human label to show on the management page later (channel
  # name or video title). Stored at insert time rather than resolved on read:
  # a blocked channel usually isn't in the local `channels` table — nothing
  # ever fetched it — so a lookup would just yield the bare id.
  def insert(user : User, kind : Kind, target_id : String, title : String? = nil)
    request = <<-SQL
      INSERT INTO not_recommended (email, kind, target_id, title, created)
      VALUES ($1, $2, $3, $4, now())
      ON CONFLICT (email, kind, target_id) DO UPDATE
      SET title = COALESCE(EXCLUDED.title, not_recommended.title)
    SQL

    PG_DB.exec(request, user.email, kind.to_db, target_id, title.presence)
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
