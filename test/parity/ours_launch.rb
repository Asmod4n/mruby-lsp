# encoding: utf-8
$LOAD_PATH.unshift "/tmp/prism-src/lib"
$LOAD_PATH.unshift "/tmp/mruby-lsp-new/lib"
ENV["MRUBY_REFLECT_SO"] = "/tmp/exttest/mruby_reflect.so"
require "mruby_lsp"
MrubyLsp.start
