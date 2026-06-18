package org.valuebridge;

import org.jruby.Ruby;
import org.jruby.RubyArray;
import org.jruby.RubyBignum;
import org.jruby.RubyBoolean;
import org.jruby.RubyClass;
import org.jruby.RubyFixnum;
import org.jruby.RubyFloat;
import org.jruby.RubyHash;
import org.jruby.RubyInteger;
import org.jruby.RubyModule;
import org.jruby.RubyNil;
import org.jruby.RubyRange;
import org.jruby.RubyString;
import org.jruby.RubySymbol;
import org.jruby.RubyTime;
import org.jruby.runtime.ThreadContext;
import org.jruby.runtime.builtin.IRubyObject;
import org.jruby.util.ByteList;

import org.jcodings.Encoding;
import org.jcodings.specific.UTF8Encoding;
import org.jcodings.specific.USASCIIEncoding;
import org.jcodings.specific.ASCIIEncoding;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;

/**
 * JRuby leg of value_bridge: IRubyObject &lt;-&gt; Node (a flat mirror of vb_value,
 * see include/vb.h). The tag set comes from VbTags, generated from the C table;
 * this file never hardcodes a tag number.
 *
 * Behavior matches the CRuby leg exactly:
 *   - the floor (nil/bool/Integer/Float/Symbol/String/Array/Hash/Range, and
 *     Bignum as base-10 text) bridges directly;
 *   - a Class/Module becomes a VB_TAGGED carrier of its qualified name;
 *   - a ValueBridge::Tagged re-encodes to its (id, payload);
 *   - everything else raises TypeError -- no opaque fallback.
 * On the way back every VB_TAGGED surfaces as a ValueBridge::Tagged carrier
 * (JRuby, like CRuby, has no per-tag decoder), so the value survives intact.
 */
public final class BridgeValue {

  private BridgeValue() {}

  // --- producer: IRubyObject -> Node ------------------------------------

  public static Node produce(Ruby runtime, IRubyObject obj) {
    ThreadContext ctx = runtime.getCurrentContext();
    Node n = new Node();

    if (obj == null || obj instanceof RubyNil) { n.tag = VbTags.VB_NIL; return n; }
    if (obj instanceof RubyBoolean) { n.tag = ((RubyBoolean) obj).isTrue() ? VbTags.VB_TRUE : VbTags.VB_FALSE; return n; }
    if (obj instanceof RubyFixnum)  { n.tag = VbTags.VB_INT;   n.i = ((RubyFixnum) obj).getLongValue(); return n; }
    if (obj instanceof RubyFloat)   { n.tag = VbTags.VB_FLOAT; n.f = ((RubyFloat) obj).getDoubleValue(); return n; }
    if (obj instanceof RubyBignum)  { n.tag = VbTags.VB_BIGINT; n.bytes = ((RubyBignum) obj).getValue().toString().getBytes(StandardCharsets.UTF_8); return n; }

    if (obj instanceof RubySymbol) {
      n.tag = VbTags.VB_SYMBOL;
      n.bytes = ((RubySymbol) obj).asJavaString().getBytes(StandardCharsets.UTF_8);
      return n;
    }
    if (obj instanceof RubyString) {
      ByteList bl = ((RubyString) obj).getByteList();
      byte[] raw = bl.bytes();                       // one copy out of the JVM
      Encoding enc = bl.getEncoding();
      boolean utf8ish = enc == UTF8Encoding.INSTANCE || enc == USASCIIEncoding.INSTANCE;
      n.tag = (utf8ish && isUtf8(raw)) ? VbTags.VB_UTF8 : VbTags.VB_BYTES;
      n.bytes = raw;
      return n;
    }
    if (obj instanceof RubyArray) {
      RubyArray<?> a = (RubyArray<?>) obj;
      int len = a.size();
      n.tag = VbTags.VB_ARRAY;
      n.items = new Node[len];
      for (int k = 0; k < len; k++) n.items[k] = produce(runtime, a.eltOk(k));
      return n;
    }
    if (obj instanceof RubyHash) {
      RubyHash h = (RubyHash) obj;
      n.tag = VbTags.VB_HASH;
      n.items = new Node[h.size() * 2];
      h.visitAll(ctx, new RubyHash.VisitorWithState<Node>() {
        @Override public void visit(ThreadContext c, RubyHash hh, IRubyObject k, IRubyObject v, int idx, Node st) {
          st.items[2 * idx]     = produce(runtime, k);
          st.items[2 * idx + 1] = produce(runtime, v);
        }
      }, n);
      return n;
    }
    if (obj instanceof RubyRange) {
      RubyRange r = (RubyRange) obj;
      n.tag = VbTags.VB_RANGE;
      n.aux = r.exclude_end_p().isTrue() ? 1 : 0;
      n.items = new Node[] { produce(runtime, r.begin(ctx)), produce(runtime, r.end(ctx)) };
      return n;
    }

    // A Time carries [sec, nsec, utc] -- absolute instant + UTC-or-local flag
    // (no zone/offset; that is all mruby can model).
    if (obj instanceof RubyTime) {
      long sec    = ((RubyInteger) obj.callMethod(ctx, "to_i").convertToInteger()).getLongValue();
      long nsec   = ((RubyInteger) obj.callMethod(ctx, "nsec").convertToInteger()).getLongValue();
      boolean utc = obj.callMethod(ctx, "utc?").isTrue();
      Node a = new Node();
      a.tag = VbTags.VB_ARRAY;
      a.items = new Node[] { intNode(sec), intNode(nsec), boolNode(utc) };
      return tagged(VbTags.VB_TAG_TIME, a);
    }

    // Beyond the floor: Class/Module carry their qualified name; a Tagged
    // re-encodes; nothing else is representable.
    if (obj instanceof RubyClass) {
      return tagged(VbTags.VB_TAG_CLASS, nameNode(runtime, (RubyModule) obj));
    }
    if (obj instanceof RubyModule) {
      return tagged(VbTags.VB_TAG_MODULE, nameNode(runtime, (RubyModule) obj));
    }
    RubyClass tc = taggedClass(runtime);
    if (tc != null && tc.isInstance(obj)) {
      int id = (int) ((RubyInteger) obj.callMethod(ctx, "tag").convertToInteger()).getLongValue();
      IRubyObject payload = obj.callMethod(ctx, "payload");
      return tagged(id, produce(runtime, payload));
    }

    throw runtime.newTypeError(
        "value_bridge: cannot represent " + obj.getMetaClass().getRealClass().getName() +
        " (no byte representation in any runtime)");
  }

  // --- consumer: Node -> IRubyObject ------------------------------------

  public static IRubyObject consume(Ruby runtime, Node n) {
    ThreadContext ctx = runtime.getCurrentContext();
    switch (n.tag) {
      case VbTags.VB_NIL:   return runtime.getNil();
      case VbTags.VB_TRUE:  return runtime.getTrue();
      case VbTags.VB_FALSE: return runtime.getFalse();
      case VbTags.VB_INT:   return runtime.newFixnum(n.i);
      case VbTags.VB_FLOAT: return runtime.newFloat(n.f);
      case VbTags.VB_SYMBOL:return runtime.newSymbol(new String(n.bytes, StandardCharsets.UTF_8));
      case VbTags.VB_UTF8:  return RubyString.newString(runtime, new ByteList(n.bytes, UTF8Encoding.INSTANCE));
      case VbTags.VB_BYTES: return RubyString.newString(runtime, new ByteList(n.bytes, ASCIIEncoding.INSTANCE));
      case VbTags.VB_BIGINT:return RubyBignum.newBignum(runtime, new BigInteger(new String(n.bytes, StandardCharsets.UTF_8)));
      case VbTags.VB_ARRAY: {
        RubyArray<?> a = runtime.newArray(n.items.length);
        for (Node child : n.items) a.append(consume(runtime, child));
        return a;
      }
      case VbTags.VB_HASH: {
        RubyHash h = RubyHash.newHash(runtime);
        for (int k = 0; k + 1 < n.items.length; k += 2)
          h.op_aset(ctx, consume(runtime, n.items[k]), consume(runtime, n.items[k + 1]));
        return h;
      }
      case VbTags.VB_RANGE: {
        IRubyObject beg = n.items.length > 0 ? consume(runtime, n.items[0]) : runtime.getNil();
        IRubyObject end = n.items.length > 1 ? consume(runtime, n.items[1]) : runtime.getNil();
        return RubyRange.newRange(ctx, beg, end, n.aux != 0);
      }
      case VbTags.VB_TAGGED: {
        if (n.tagId == VbTags.VB_TAG_TIME) return consumeTime(runtime, n.payload);
        RubyClass tc = taggedClass(runtime);
        IRubyObject payload = consume(runtime, n.payload);
        return tc.callMethod(ctx, "new", new IRubyObject[] { runtime.newFixnum(n.tagId), payload });
      }
      default:
        return runtime.getNil();
    }
  }

  // --- helpers ----------------------------------------------------------

  private static Node tagged(int id, Node payload) {
    Node n = new Node();
    n.tag = VbTags.VB_TAGGED;
    n.tagId = id;
    n.payload = payload;
    return n;
  }

  private static Node nameNode(Ruby runtime, RubyModule mod) {
    String name = mod.getName();
    return produce(runtime, name == null ? runtime.getNil() : runtime.newString(name));
  }

  private static RubyClass taggedClass(Ruby runtime) {
    RubyModule mod = runtime.getModule("ValueBridge");
    if (mod == null) return null;
    IRubyObject k = mod.getConstantAt("Tagged");
    return (k instanceof RubyClass) ? (RubyClass) k : null;
  }

  private static Node intNode(long v)  { Node n = new Node(); n.tag = VbTags.VB_INT; n.i = v; return n; }
  private static Node boolNode(boolean b){ Node n = new Node(); n.tag = b ? VbTags.VB_TRUE : VbTags.VB_FALSE; return n; }

  private static IRubyObject consumeTime(Ruby runtime, Node a) {
    ThreadContext ctx = runtime.getCurrentContext();
    long sec = 0, nsec = 0; boolean utc = false;
    if (a != null && a.items != null && a.items.length >= 3) {
      sec  = a.items[0].i;
      nsec = a.items[1].i;
      utc  = a.items[2].tag == VbTags.VB_TRUE;
    }
    RubyClass timeClass = (RubyClass) runtime.getObject().getConstant("Time");
    IRubyObject t = timeClass.callMethod(ctx, "at", new IRubyObject[] {
        runtime.newFixnum(sec), runtime.newFixnum(nsec), runtime.newSymbol("nanosecond") });
    if (utc) t = t.callMethod(ctx, "utc");
    return t;
  }

  // mirror of vb_is_utf8 (src/vb.c) so both legs agree on the UTF8/BYTES split
  private static boolean isUtf8(byte[] b) {
    int i = 0, len = b.length;
    while (i < len) {
      int c = b[i] & 0xFF;
      if (c < 0x80) { i++; continue; }
      int need, cp;
      if      ((c & 0xE0) == 0xC0) { need = 1; cp = c & 0x1F; }
      else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
      else if ((c & 0xF8) == 0xF0) { need = 3; cp = c & 0x07; }
      else return false;
      if (i + need >= len) return false;
      for (int k = 1; k <= need; k++) {
        int cc = b[i + k] & 0xFF;
        if ((cc & 0xC0) != 0x80) return false;
        cp = (cp << 6) | (cc & 0x3F);
      }
      if (need == 1 && cp < 0x80)    return false;
      if (need == 2 && cp < 0x800)   return false;
      if (need == 3 && cp < 0x10000) return false;
      if (cp > 0x10FFFF) return false;
      if (cp >= 0xD800 && cp <= 0xDFFF) return false;
      i += need + 1;
    }
    return true;
  }
}
