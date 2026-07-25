require "pg"

module Invidious::Database
  extend self

  # Checks table integrity
  #
  # Note: config is passed as a parameter to avoid complex
  # dependencies between different parts of the software.
  def check_integrity(cfg)
    return if !cfg.check_tables
    Invidious::Database.check_enum("privacy", PlaylistPrivacy)

    Invidious::Database.check_table("channels", InvidiousChannel)
    Invidious::Database.check_table("channel_videos", ChannelVideo)
    Invidious::Database.check_table("playlists", InvidiousPlaylist)
    Invidious::Database.check_table("playlist_videos", PlaylistVideo)
    Invidious::Database.check_table("nonces", Nonce)
    Invidious::Database.check_table("session_ids", SessionId)
    Invidious::Database.check_table("users", User)
    Invidious::Database.check_table("videos", Video)

    if cfg.cache_annotations
      Invidious::Database.check_table("annotations", Annotation)
    end
  end

  #
  # Table/enum integrity checks
  #

  def check_enum(enum_name, struct_type = nil)
    return # TODO

    if !PG_DB.query_one?("SELECT true FROM pg_type WHERE typname = $1", enum_name, as: Bool)
      LOGGER.info("check_enum: CREATE TYPE #{enum_name}")

      PG_DB.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{enum_name}.sql"))
      end
    end
  end

  def check_table(table_name, struct_type = nil)
    # Create table if it doesn't exist
    begin
      PG_DB.exec("SELECT * FROM #{table_name} LIMIT 0")
    rescue ex
      LOGGER.info("check_table: check_table: CREATE TABLE #{table_name}")

      PG_DB.using_connection do |conn|
        conn.as(PG::Connection).exec_all(File.read("config/sql/#{table_name}.sql"))
      end
    end

    return if !struct_type

    struct_array = struct_type.type_array
    column_array = get_column_array(PG_DB, table_name)
    column_types = File.read("config/sql/#{table_name}.sql").match(/CREATE TABLE public\.#{table_name}\n\((?<types>[\d\D]*?)\);/)
      .try &.["types"].split(",").map(&.strip).reject &.starts_with?("CONSTRAINT")

    return if !column_types

    struct_array.each_with_index do |name, i|
      if name != column_array[i]?
        if !column_array[i]?
          new_column = column_types.select(&.starts_with?(name))[0]
          LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
          next
        end

        # Column doesn't exist
        if !column_array.includes? name
          new_column = column_types.select(&.starts_with?(name))[0]
          PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
        end

        # Column exists but in the wrong position, rotate
        if struct_array.includes? column_array[i]
          until name == column_array[i]
            new_column = column_types.select(&.starts_with?(column_array[i]))[0]?.try &.gsub("#{column_array[i]}", "#{column_array[i]}_new")

            # There's a column we didn't expect
            if !new_column
              LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]}")
              PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

              column_array = get_column_array(PG_DB, table_name)
              next
            end

            LOGGER.info("check_table: ALTER TABLE #{table_name} ADD COLUMN #{new_column}")
            PG_DB.exec("ALTER TABLE #{table_name} ADD COLUMN #{new_column}")

            LOGGER.info("check_table: UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")
            PG_DB.exec("UPDATE #{table_name} SET #{column_array[i]}_new=#{column_array[i]}")

            LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
            PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")

            LOGGER.info("check_table: ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")
            PG_DB.exec("ALTER TABLE #{table_name} RENAME COLUMN #{column_array[i]}_new TO #{column_array[i]}")

            column_array = get_column_array(PG_DB, table_name)
          end
        else
          LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
          PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column_array[i]} CASCADE")
        end
      end
    end

    return if column_array.size <= struct_array.size

    column_array.each do |column|
      if !struct_array.includes? column
        LOGGER.info("check_table: ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
        PG_DB.exec("ALTER TABLE #{table_name} DROP COLUMN #{column} CASCADE")
      end
    end
  end

  # Applies schema additions that features depend on, regardless of the
  # `check_tables` setting (which is off by default). Each statement is
  # idempotent, so this is safe to run on every boot.
  #
  # Without this, instances that don't run `--migrate` or enable
  # `check_tables` never get the `is_short` column, and anything that reads
  # it (Shorts filtering, the subscription feed view) fails with
  # "column \"is_short\" does not exist".
  def ensure_feature_columns
    # shorts-filter: per-user playback positions table. Created here (not just
    # via --migrate) so it always exists, matching the is_short handling below.
    begin
      PG_DB.exec(
        "CREATE TABLE IF NOT EXISTS public.playback_positions " \
        "(email text NOT NULL, video_id text NOT NULL, position integer NOT NULL, " \
        "updated timestamptz DEFAULT now(), PRIMARY KEY (email, video_id))"
      )
    rescue ex
      LOGGER.error("ensure_feature_columns: playback_positions : #{ex.message}")
    end

    # shorts-filter: per-user "don't recommend" list, same reasoning — every
    # read path (Discover ranking, related-video filtering) queries this on
    # any logged-in request, so it has to exist without a manual --migrate.
    # Must stay above the is_short block, which returns early.
    begin
      PG_DB.exec(
        "CREATE TABLE IF NOT EXISTS public.not_recommended " \
        "(email text NOT NULL, kind text NOT NULL, target_id text NOT NULL, " \
        "created timestamptz DEFAULT now(), PRIMARY KEY (email, kind, target_id))"
      )
    rescue ex
      LOGGER.error("ensure_feature_columns: not_recommended : #{ex.message}")
    end

    begin
      already_present = PG_DB.query_one(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns " \
        "WHERE table_name = 'channel_videos' AND column_name = 'is_short')",
        as: Bool
      )

      return if already_present

      LOGGER.info("ensure_feature_columns: ALTER TABLE channel_videos ADD COLUMN is_short")
      PG_DB.exec("ALTER TABLE channel_videos ADD COLUMN IF NOT EXISTS is_short boolean DEFAULT false")

      # The per-user subscription materialized views snapshot columns at
      # creation (SELECT cv.*), so they're now stale. Flag every feed for
      # update; RefreshFeedsJob drops and recreates stale views automatically.
      PG_DB.exec("UPDATE users SET feed_needs_update = true")
    rescue ex
      LOGGER.error("ensure_feature_columns: channel_videos.is_short : #{ex.message}")
    end
  end

  def get_column_array(db, table_name)
    column_array = [] of String
    PG_DB.query("SELECT * FROM #{table_name} LIMIT 0") do |rs|
      rs.column_count.times do |i|
        column = rs.as(PG::ResultSet).field(i)
        column_array << column.name
      end
    end

    return column_array
  end
end
