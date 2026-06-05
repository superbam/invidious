module Invidious::Database::Migrations
  class AddIsShortToChannelVideos < Migration
    version 11

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.channel_videos
        ADD COLUMN IF NOT EXISTS is_short boolean DEFAULT false;
      SQL
    end
  end
end
