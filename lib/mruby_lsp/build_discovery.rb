# frozen_string_literal: true

require "yaml"
require "json"
require "etc"

module MrubyLsp
  module Discovery
    # T9: discover which build config to reflect, anchored on mruby's own
    # lockfile (*.rb.lock) rather than a hardcoded build_config.rb.
    #
    # Ground truth (lib/mruby/lockfile.rb): a build writes "#{MRUBY_CONFIG}.lock"
    # next to the config, YAML of the shape:
    #   mruby:  {version:, release_no:, git_commit:}
    #   builds: {<target_name> => {...}, ...}
    # A lock is a real candidate iff its "builds" hash is non-empty (>=1 build).
    # The config for a lock is the lock path minus ".lock".
    #
    # Resolution order:
    #   1. a persisted choice in the OUT-OF-WORKSPACE state store
    #      ($XDG_DATA_HOME/mruby-lsp/workspaces/<slug>/config.json) that still
    #      exists and still has >=1 build -> use it, no questions.
    #   2. exactly one valid candidate in the workspace -> use it.
    #   3. more than one -> AMBIGUOUS (caller asks the user; we never guess).
    #   4. zero -> NONE (caller tells the user to build once first).
    #
    # Trust/decision state lives in the XDG state store (see state_dir /
    # config_store_path), NEVER in the workspace -- a cloned/hostile repo must
    # not be able to forge "set up" or build consent. This module is the single
    # reader/writer of that store; editors are UI over it.
    module BuildDiscovery
      Candidate = Struct.new(:lock_path, :config_path, :builds, keyword_init: true)

      # Result of a discovery attempt. `status` is one of:
      #   :resolved   -> `config_path` is the answer
      #   :ambiguous  -> `candidates` needs a user choice
      #   :none       -> nothing built yet
      Result = Struct.new(:status, :config_path, :candidates, :source, keyword_init: true)

      CONFIG_FILE = "config.json"

      module_function

      # The user's home directory, resolved ENV-FREE from the passwd database
      # (getpwuid), NOT from $HOME. This is the same source the C launcher uses
      # to build its Landlock allow-list, so the cache/state dirs the Ruby side
      # writes always land inside the tree the launcher permits — env can't make
      # the two disagree, and can't redirect our work-root. Falls back to
      # Dir.home only if the passwd lookup somehow fails (no entry for the uid).
      def home_dir
        Etc.getpwuid(Process.uid).dir
      rescue ArgumentError, SystemCallError
        Dir.home
      end

      # THE cache dir for a workspace: <home>/.cache/mruby-lsp/<path-slug>.
      # Single source of truth — setup, the server, and update all derive the
      # path this way so they always agree. Build artifacts live HERE (never in
      # the user's project). The workspace is canonicalized so equivalent paths
      # map to the same cache.
      #
      # The root is the passwd home (see home_dir), NOT $XDG_CACHE_HOME: this is
      # part of the sandbox trust boundary, where the environment must steer
      # nothing — the launcher's Landlock allow-list is computed the same way, so
      # the two can never diverge. We keep the standard `.cache` layout name.
      #
      # The slug is the FULL absolute path with separators flattened (NO hash):
      # /home/h/code/mruby-cbor -> home_h_code_mruby-cbor. Deterministic and
      # human-readable, and identical to the JS side's slug — so the extension
      # and the server can never disagree about which folder the build is in.
      def cache_dir(workspace)
        workspace = File.expand_path(workspace)
        File.join(home_dir, ".cache", "mruby-lsp", path_slug(workspace))
      end

      # Air-gap layout (sandbox iteration: FS separation). Under the per-workspace
      # cache root, fetched gem CLONES and built ARTIFACTS live in DISJOINT
      # siblings, so a compromised fetch can't write into the tree we later build,
      # and the build can't scribble back over fetched sources:
      #   <cache>/fetch/   <- network writes here (gem clones); build reads it
      #   <cache>/build/   <- offline build writes here; never the fetch tree
      # setup passes fetch_dir to the wrapper (MRUBY_LSP_FETCH_DIR), which points
      # mruby's gem_clone_dir here instead of the default <build_dir>/repos.
      def fetch_dir(workspace)
        File.join(cache_dir(workspace), "fetch")
      end

      # The build-artifact root (libmruby + the reflect build live under here).
      def build_dir(workspace)
        File.join(cache_dir(workspace), "build")
      end

      # Flatten an absolute path into a single filesystem-safe directory name.
      # Every run of non [A-Za-z0-9._-] characters (notably the path separators)
      # becomes one underscore; leading separator underscores are trimmed. Must
      # stay byte-identical to slug() in editors/vscode/src/extension.ts.
      def path_slug(abs_path)
        abs_path.gsub(/[^A-Za-z0-9._-]+/, "_").sub(/\A_+/, "")
      end

      # Main entry. workspace: absolute path to the project root.
      def discover(workspace)
        workspace = File.expand_path(workspace)

        # 1. persisted choice
        saved = read_saved_choice(workspace)
        if saved && valid_candidate?(saved)
          return Result.new(status: :resolved, config_path: saved, source: :saved)
        end

        # 2/3/4. scan
        cands = candidates(workspace)
        case cands.length
        when 0
          Result.new(status: :none, candidates: [])
        when 1
          Result.new(status: :resolved, config_path: cands.first.config_path,
                     candidates: cands, source: :single)
        else
          Result.new(status: :ambiguous, candidates: cands)
        end
      end

      # All valid candidates in the workspace (locks with >=1 build), sorted
      # for stable presentation.
      def candidates(workspace)
        Dir.glob(File.join(workspace, "**", "*.rb.lock")).sort.filter_map do |lock|
          builds = builds_in(lock)
          # mruby 4 lockfiles dropped the "builds" key entirely (only
          # mruby: {version, release_no, git_commit} remains). A lock that
          # parses and names an mruby is still proof of a real built config —
          # require "builds" only when the key exists (pre-4 format).
          next if builds.nil?
          Candidate.new(lock_path: lock, config_path: lock.sub(/\.lock\z/, ""),
                        builds: builds.keys)
        end
      end

      # Structurally parse a lock's "builds" hash. Returns nil on any problem
      # (missing, unreadable, malformed, not the expected shape) -- never raises.
      def builds_in(lock_path)
        return nil unless File.file?(lock_path)
        data = YAML.safe_load(File.read(lock_path))
        return nil unless data.is_a?(Hash)
        builds = data["builds"]
        return builds if builds.is_a?(Hash)
        # mruby 4 format: no "builds" key, but a parsed lock with an "mruby"
        # section is valid — report zero named builds rather than rejecting.
        data["mruby"].is_a?(Hash) ? {} : nil
      end

      # A persisted config path is valid if its sibling lock still records
      # >=1 build.
      def valid_candidate?(config_path)
        return false unless config_path && File.file?(config_path)
        b = builds_in("#{config_path}.lock")
        !b.nil? && !b.empty?
      end

      # ---- persisted choice (state store, OUTSIDE the workspace) -------------
      #
      # SECURITY: our trust/decision state (chosen config, mruby_root, consent,
      # setup-done) must NEVER live in the workspace — a cloned/hostile repo
      # could forge it to point us at attacker paths or flip consent. It lives in
      # the user's own dir, keyed by the canonical workspace path, where a repo
      # cannot write. We create nothing inside the user's project.
      def state_dir(workspace)
        workspace = File.expand_path(workspace)
        # Passwd home, NOT $XDG_DATA_HOME — same trust-boundary reasoning as
        # cache_dir: env must not be able to relocate where our trust/decision
        # state lives. Standard `.local/share` layout under the env-free home.
        File.join(home_dir, ".local", "share", "mruby-lsp", "workspaces", path_slug(workspace))
      end

      def config_store_path(workspace)
        File.join(state_dir(workspace), CONFIG_FILE)
      end

      def read_saved_choice(workspace)
        path = config_store_path(workspace)
        return nil unless File.file?(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data["config"] : nil
      end

      # Resolve the mruby source checkout (where rake runs) without an arg:
      #   1. saved mruby_root in the XDG state store config.json (still a checkout)
      #   2. autodetect a sibling/child mruby checkout under the workspace
      #      (a dir containing a Rakefile and an mrbgems/ -- the conventional
      #      `<project>/mruby` layout, or any single such dir one level deep)
      # Returns nil if none found (caller then asks for it once).
      def resolve_mruby_root(workspace)
        workspace = File.expand_path(workspace)
        saved = saved_field(workspace, "mruby_root")
        return saved if saved && mruby_checkout?(saved)

        # common case: <workspace>/mruby
        direct = File.join(workspace, "mruby")
        return direct if mruby_checkout?(direct)

        # otherwise: a unique mruby-ish checkout one level down
        found = Dir.glob(File.join(workspace, "*")).select { |d| mruby_checkout?(d) }
        found.length == 1 ? found.first : nil
      end

      # An mruby SOURCE checkout (where rake runs), identified by its
      # structural signature -- NOT by any config filename (those are
      # user-chosen and arbitrary). The combination below is unique to an
      # mruby source tree and won't false-match a Rails/Ruby app's Rakefile.
      def mruby_checkout?(dir)
        return false unless dir && File.directory?(dir)
        File.file?(File.join(dir, "Rakefile")) &&
          File.directory?(File.join(dir, "mrbgems")) &&
          File.directory?(File.join(dir, "mrblib")) &&
          File.file?(File.join(dir, "include", "mruby.h")) &&
          File.directory?(File.join(dir, "lib", "mruby"))
      end

      def saved_field(workspace, key)
        path = config_store_path(workspace)
        return nil unless File.file?(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data[key] : nil
      end

      # Persist the chosen config (and mruby_root, so re-runs need no args).
      def save_choice(workspace, config_path, mruby_root: nil)
        dir = state_dir(workspace)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        payload = read_config(workspace)
        payload["config"] = File.expand_path(config_path)
        payload["mruby_root"] = File.expand_path(mruby_root) if mruby_root
        File.write(File.join(dir, CONFIG_FILE), JSON.pretty_generate(payload) + "\n")
        config_path
      end

      # Is the cached reflection artifact stale -- i.e. did the user rebuild
      # their project (lock rewritten) since we last built our reflection .so?
      # A rebuild rewrites <config>.rb.lock (mruby's Lockfile.write) regardless
      # of where build artifacts land, so the lock mtime is the reliable,
      # layout-independent signal. No file watcher: callers poll this cheaply
      # (a couple of stats) on a debounce.
      #
      # reflect_so: absolute path to our cached artifact (from paths.env).
      # config_path: the resolved user config (its sibling .lock is the signal).
      # Returns true only when both exist AND the lock is newer than the .so.
      def stale?(reflect_so, config_path)
        return false unless reflect_so && config_path
        lock = "#{config_path}.lock"
        return false unless File.file?(reflect_so) && File.file?(lock)
        File.mtime(lock) > File.mtime(reflect_so)
      end

      # "Never ask to build in this workspace" -- the consent-layer opt-out.
      def build_opt_out?(workspace)
        read_config(workspace)["build_opt_out"] == true
      end

      def set_build_opt_out(workspace, value)
        dir = state_dir(workspace)
        require "fileutils"
        FileUtils.mkdir_p(dir)
        payload = read_config(workspace)
        payload["build_opt_out"] = value
        File.write(File.join(dir, CONFIG_FILE), JSON.pretty_generate(payload) + "\n")
        value
      end

      def read_config(workspace)
        path = config_store_path(workspace)
        return {} unless File.file?(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : {}
      end
    end
  end
end

# CLI: `ruby build_discovery.rb <workspace>` prints the resolution outcome as
# key=value lines for the setup script / launcher to consume.
if $PROGRAM_NAME == __FILE__
  ws = ARGV[0] || Dir.pwd
  r = MrubyLsp::Discovery::BuildDiscovery.discover(ws)
  puts "status=#{r.status}"
  case r.status
  when :resolved
    puts "config=#{r.config_path}"
    puts "source=#{r.source}"
  when :ambiguous
    r.candidates.each_with_index do |c, i|
      puts "candidate#{i}=#{c.config_path} (builds: #{c.builds.join(',')})"
    end
  when :none
    puts "message=no built mruby config found in #{File.expand_path(ws)} -- run a build once first"
  end
end
