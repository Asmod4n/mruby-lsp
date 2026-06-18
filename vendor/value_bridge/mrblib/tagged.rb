module ValueBridge
  class Tagged
    CLASS = 1; MODULE = 2; RATIONAL = 3; COMPLEX = 4; TIME = 5; SET = 6; PROC = 7
    EXCEPTION_MRUBY = 8; EXCEPTION_CRUBY = 9; EXCEPTION_JRUBY = 10
    attr_reader :tag, :payload
    def initialize(tag, payload) @tag = tag.to_i; @payload = payload end
    def ==(o) o.is_a?(Tagged) && o.tag == tag && o.payload == payload end
  end
end
