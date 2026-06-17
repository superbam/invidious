module Invidious::Database::Migrations
  class CreatePlaybackPositionsTable < Migration
    version 12

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      CREATE TABLE IF NOT EXISTS public.playback_positions
      (
        email text NOT NULL,
        video_id text NOT NULL,
        position integer NOT NULL,
        updated timestamptz DEFAULT now(),
        PRIMARY KEY (email, video_id)
      );
      SQL

      conn.exec <<-SQL
      GRANT ALL ON TABLE public.playback_positions TO current_user;
      SQL
    end
  end
end
