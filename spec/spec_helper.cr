require "kemal"
require "openssl/hmac"
require "pg"
require "protodec/utils"
require "yaml"
# Config has to come before anything that reads CONFIG in a property default
# (user/preferences.cr does). Only base_job is needed alongside it: jobs.cr
# generates JobsConfig from BaseJob.subclasses in a `macro finished`, and an
# empty set of subclasses is fine for specs.
require "../src/invidious/jobs/base_job"
require "../src/invidious/jobs"
require "../src/invidious/config"
require "../src/invidious/helpers/*"
require "../src/invidious/channels/*"
require "../src/invidious/videos/caption"
require "../src/invidious/videos"
require "../src/invidious/playlists"
require "../src/invidious/search/ctoken"
require "../src/invidious/trending"
require "../src/invidious/user/preferences"
require "../src/invidious/user/user"
require "../src/invidious/jsonify/api_v1/common"
require "../src/invidious/not_recommended"
require "../src/invidious/discover"
require "spectator"

# Defined here rather than in one arbitrary spec file so that running a single
# spec works too — anything requiring this helper transitively reads CONFIG.
CONFIG = Config.from_yaml(File.open("config/config.example.yml"))

Spectator.configure do |config|
  config.fail_blank
  config.randomize
end
