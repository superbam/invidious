require "./base.cr"

#
# shorts-filter: per-user playback positions.
#
# Stock Invidious only saves resume positions in the browser's localStorage
# (see assets/js/watched_indicator.js), so they never sync across devices and
# there's no API for clients. This table backs a small authenticated API
# (/api/v1/auth/positions) that native clients (e.g. Yattee) use to sync the
# resume point. Watched/unwatched state stays in users.watched as before.
#
module Invidious::Database::PlaybackPositions
  extend self

  # Returns every stored playback position for the user as a
  # { video_id => seconds } map.
  def select_all(user : User) : Hash(String, Int32)
    request = <<-SQL
      SELECT video_id, position FROM playback_positions
      WHERE email = $1
    SQL

    PG_DB.query_all(request, user.email, as: {String, Int32}).to_h
  end

  # Returns the stored playback position (seconds) for a single video, or nil
  # if none. Used to seed the web player's resume point from the synced store.
  def get(user : User, vid : String) : Int32?
    request = <<-SQL
      SELECT position FROM playback_positions
      WHERE email = $1 AND video_id = $2
    SQL

    PG_DB.query_one?(request, user.email, vid, as: Int32)
  end

  # Inserts or updates the playback position (in seconds) for a single video.
  def upsert(user : User, vid : String, position : Int32)
    request = <<-SQL
      INSERT INTO playback_positions (email, video_id, position, updated)
      VALUES ($1, $2, $3, now())
      ON CONFLICT (email, video_id) DO UPDATE
      SET position = $3, updated = now()
    SQL

    PG_DB.exec(request, user.email, vid, position)
  end

  def delete(user : User, vid : String)
    request = <<-SQL
      DELETE FROM playback_positions
      WHERE email = $1 AND video_id = $2
    SQL

    PG_DB.exec(request, user.email, vid)
  end

  def clear(user : User)
    request = <<-SQL
      DELETE FROM playback_positions
      WHERE email = $1
    SQL

    PG_DB.exec(request, user.email)
  end
end
