# frozen_string_literal: true
module ValueBridge
  # A value carried by tag id + decoded payload, for types beyond the floor. The
  # tag id alone names what it is (e.g. PROC => an mruby proc's irep blob); no
  # separate origin is needed. A runtime without a codec for the tag surfaces it
  # as Tagged, which re-encodes intact, so the value survives the hop and a host
  # that can decode it (e.g. one embedding an mruby VM for PROC) still can.
  class Tagged
    CLASS = 1; MODULE = 2; RATIONAL = 3; COMPLEX = 4; TIME = 5; SET = 6; PROC = 7
    EXCEPTION_MRUBY = 8; EXCEPTION_CRUBY = 9; EXCEPTION_JRUBY = 10
    attr_reader :tag, :payload
    def initialize(tag, payload) @tag = Integer(tag); @payload = payload end
    def ==(o) o.is_a?(Tagged) && o.tag == tag && o.payload == payload end
    def inspect; "#<ValueBridge::Tagged tag=#{tag} payload=#{payload.inspect}>"; end
  end
end
