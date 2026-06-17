-- Table: public.playback_positions

-- DROP TABLE public.playback_positions;

CREATE TABLE IF NOT EXISTS public.playback_positions
(
    email text NOT NULL,
    video_id text NOT NULL,
    position integer NOT NULL,
    updated timestamptz DEFAULT now(),
    PRIMARY KEY (email, video_id)
);

GRANT ALL ON TABLE public.playback_positions TO current_user;
