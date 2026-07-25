module Invidious::Database::Migrations
  class CreateNotRecommendedTable < Migration
    version 13

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      CREATE TABLE IF NOT EXISTS public.not_recommended
      (
        email text NOT NULL,
        kind text NOT NULL,
        target_id text NOT NULL,
        created timestamptz DEFAULT now(),
        PRIMARY KEY (email, kind, target_id)
      );
      SQL

      conn.exec <<-SQL
      GRANT ALL ON TABLE public.not_recommended TO current_user;
      SQL
    end
  end
end
