# frozen_string_literal: true

require "rbconfig"

module MrubyLsp
  # Resolves a C method's source location from the offset the reflection C-ext
  # emits. The offset is computed in the C-ext as:
  #
  #     off = (intptr_t)cfunc_ptr - (intptr_t)&mrb_open
  #
  # i.e. relative to the exported anchor `mrb_open` (ASLR-invariant, and equal to
  # nm's addr(cfunc) - addr(mrb_open) on the linked image). So the host join is:
  #
  #     real_vaddr = nm_addr(mrb_open) + offset
  #     addr2line(real_vaddr) -> function name + C file:line
  #
  # Requires the reflect_so to be built with -g (debug_info) — which the wrapper
  # build_config enables via conf.enable_debug. Without it, addr2line yields "??"
  # and we degrade to nil (no crash).
  class CLocator
    def self.open(so_path = ENV["MRUBY_REFLECT_SO"], platform:)
      return nil unless so_path && File.exist?(so_path)

      anchor = nm_symbol_addr(so_path, "mrb_open")
      return nil unless anchor

      new(so_path, anchor, platform: platform)
    end

    def initialize(so_path, anchor_addr, platform:)
      @so = so_path
      @anchor = anchor_addr
      @cache = {} # offset -> [func, file, line] | nil
      # Symbolizer backend, chosen from the VM-baked Platform facts (not host
      # guessing). GNU DWARF (addr2line) covers Linux for both gcc and clang.
      # macOS (atos/dwarfdump) and Windows/MSVC (PDB) need different tooling and
      # a different invocation shape -- NOT wired yet, so C source locations are
      # gated OFF there (the LSP still runs, C go-to-def just doesn't) rather than
      # feed addr2line a format it can't read. An OS the C side never emits is a
      # sync error, not a runtime condition: raise, don't silently pick a backend.
      @backend =
        case platform[:os]
        # ELF + DWARF Unix: Linux and the BSDs all resolve via an addr2line-shaped
        # symbolizer (GNU binutils, elftoolchain, or LLVM — we prefer llvm-* below).
        when :linux, :freebsd, :netbsd, :openbsd, :dragonfly then :gnu
        when :macos, :windows, :unknown then nil   # gated: no symbolizer wired yet
        else raise "mruby-lsp: unexpected Platform::OS #{platform[:os].inspect}"
        end
    end

    # Which symbolizer backend this locator resolved to (:gnu or nil-gated).
    attr_reader :backend

    # binutils/symbolizer tool resolution, LLVM FIRST. `llvm-addr2line`/`llvm-nm`
    # are drop-ins for GNU's WITH our explicit `-f -C` flags (llvm-addr2line
    # otherwise defaults to no function names and no demangling), they read
    # addresses from stdin like GNU (the batched #prime path) — where elftoolchain
    # may not — and they are what clang-based BSDs and FreeBSD 15+ ship (its
    # binutils migrated to LLVM). Fall back to the plain GNU/elftoolchain name.
    # Resolved against PATH once and memoized.
    def self.addr2line_cmd
      @addr2line_cmd ||= resolve_tool(%w[llvm-addr2line addr2line])
    end

    def self.nm_cmd
      @nm_cmd ||= resolve_tool(%w[llvm-nm nm])
    end

    # First candidate found on PATH (honoring EXEEXT); else the last (plain) name
    # so a genuinely missing binary surfaces as ENOENT at the spawn site, where it
    # is caught and degrades to "no C locations" rather than crashing.
    def self.resolve_tool(candidates)
      ext   = RbConfig::CONFIG["EXEEXT"].to_s
      paths = (ENV["PATH"] || "").split(File::PATH_SEPARATOR).reject(&:empty?)
      candidates.each do |name|
        paths.each do |dir|
          p = File.join(dir, name + ext)
          return p if File.file?(p) && File.executable?(p)
        end
      end
      candidates.last
    end

    # Resolve MANY offsets in ONE addr2line process (stdin-fed, 2 output lines
    # per address, order-preserving) and fill the cache. ~50ms for the whole VM
    # vs one process spawn PER method (~25ms each, the original 18s populate).
    # After this, every per-offset resolve() is a cache hit -- zero spawns.
    def prime(offsets)
      return if @backend != :gnu
      todo = offsets.select { |o| o.is_a?(Integer) && !@cache.key?(o) }.uniq
      return if todo.empty?

      out = nil
      begin
        IO.popen([CLocator.addr2line_cmd, "-f", "-C", "-e", @so], "r+", err: File::NULL) do |io|
          todo.each { |o| io.puts format("0x%x", @anchor + o) }
          io.close_write
          out = io.read
        end
      rescue SystemCallError => e
        warn "mruby-lsp: #{CLocator.addr2line_cmd} unavailable (#{e.class}); C source locations disabled"
        @backend = nil
        return
      end
      lines = out.to_s.split("\n")
      # Pairing is positional (2 lines per address). If the tool emits ANY
      # extra/missing line (DWARF warnings, version quirks), every later pair
      # shifts and methods get their NEIGHBOR'S location (field: upcase ->
      # pack.c). Verify the invariant; on mismatch fall back to per-offset
      # resolution -- slow but never wrong.
      unless lines.size == 2 * todo.size
        warn "mruby-lsp: addr2line batch desync (#{lines.size} lines for #{todo.size} addrs); falling back to per-address resolution"
        todo.each { |off| resolve(off) }
        return
      end
      todo.each_with_index do |off, i|
        func = lines[2 * i]&.strip
        fileline = lines[2 * i + 1]&.strip
        @cache[off] =
          if func.nil? || func.empty? || func == "??" || fileline.nil? || fileline.start_with?("??")
            nil
          else
            file, line = split_fileline(fileline)
            [func, file, line]
          end
      end
    end

    # offset: the integer cfunc_offset from the reflection C-ext.
    # Returns [func_name, file_path, line] or nil.
    def resolve(offset)
      return nil unless offset.is_a?(Integer)
      return nil unless @backend == :gnu
      return @cache[offset] if @cache.key?(offset)

      vaddr = @anchor + offset
      out =
        begin
          IO.popen([CLocator.addr2line_cmd, "-f", "-C", "-e", @so, format("0x%x", vaddr)],
                   err: File::NULL, &:read)
        rescue SystemCallError => e
          warn "mruby-lsp: #{CLocator.addr2line_cmd} unavailable (#{e.class}); C source locations disabled"
          @backend = nil
          return nil
        end
      lines = out.to_s.split("\n")
      func = lines[0]&.strip
      fileline = lines[1]&.strip

      if func.nil? || func.empty? || func == "??" || fileline.nil? || fileline.start_with?("??")
        return (@cache[offset] = nil)
      end

      file, line = split_fileline(fileline)
      @cache[offset] = [func, file, line]
    end

    def self.nm_symbol_addr(so_path, symbol)
      out = IO.popen([nm_cmd, so_path], err: File::NULL, &:read)
      out.each_line do |l|
        parts = l.split
        next unless parts.size >= 3
        addr, type, name = parts[0], parts[1], parts[2]
        next unless name == symbol
        next unless %w[t T].include?(type) # text (code) symbol
        return addr.to_i(16)
      end
      nil
    rescue SystemCallError
      # nm / llvm-nm not on PATH -> no anchor -> open() returns nil -> C source
      # locations are simply off on this host (no crash).
      nil
    end

    private

    def split_fileline(fileline)
      # "path/to/file.c:3098" or with column "file.c:3098:5"
      idx = fileline.rindex(":")
      return [fileline, nil] unless idx

      path = fileline[0...idx]
      rest = fileline[(idx + 1)..]
      line = rest.to_i
      # Handle "file.c:line:col"
      if line.zero? && path.include?(":")
        idx2 = path.rindex(":")
        line = path[(idx2 + 1)..].to_i
        path = path[0...idx2]
      end
      [path, line.positive? ? line : nil]
    end
  end
end
