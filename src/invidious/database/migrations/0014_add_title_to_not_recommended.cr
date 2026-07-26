module Invidious::Database::Migrations
  class AddTitleToNotRecommended < Migration
    version 14

    def up(conn : DB::Connection)
      conn.exec <<-SQL
      ALTER TABLE public.not_recommended
        ADD COLUMN IF NOT EXISTS title text;
      SQL
    end
  end
end
