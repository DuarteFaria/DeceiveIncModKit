"""Run DIScore's hand-rolled JSON encoder under real Lua and validate with
Python's json parser. Extracts the encoder block from the mod so the test
always exercises the shipped code."""
import io, json, re, sys
import lupa

src = io.open(sys.argv[1], encoding="utf-8").read()

start = src.index("local json_encode")
end = src.index("local function unwrap")
block = src[start:end]

L = lupa.LuaRuntime(unpack_returned_tuples=True)
# The block declares everything `local`, which would fall out of scope at the
# end of the chunk; re-export so the test can call them.
L.execute(block + "\n_G.json_encode = json_encode\n_G.array = array\n")

def check(name, lua_expr, expected=None):
    out = L.eval("json_encode(%s)" % lua_expr)
    try:
        parsed = json.loads(out)
    except Exception as e:
        print("FAIL %-28s unparseable: %s\n     %s" % (name, e, out))
        return False
    if expected is not None and parsed != expected:
        print("FAIL %-28s got %r want %r" % (name, parsed, expected))
        return False
    print("ok   %-28s %s" % (name, out[:90]))
    return True

ok = True
ok &= check("integer", "3", 3)
ok &= check("float", "1.5", 1.5)
ok &= check("negative", "-1", -1)
ok &= check("bool", "true", True)
ok &= check("string", '"hi"', "hi")
ok &= check("quote escape", r'''"he said \"hi\""''', 'he said "hi"')
ok &= check("backslash", r'''"a\\b"''', "a\\b")
ok &= check("newline in string", r'''"a\nb"''', "a\nb")
ok &= check("tab in string", r'''"a\tb"''', "a\tb")
# Accented bot name straight from the live log.
ok &= check("utf8 name", '"Cavalière"', "Cavalière")
ok &= check("empty array", "array()", [])
ok &= check("array", "array({1,2,3})", [1, 2, 3])
ok &= check("empty object", "{}", {})
ok &= check("nested", 'array({{a=1},{b=array({2})}})', [{"a": 1}, {"b": [2]}])
ok &= check("sorted keys", '{z=1,a=2,m=3}')
ok &= check("numeric-ish key", '{["2"]=1}', {"2": 1})
ok &= check("nan", "0/0", None)
ok &= check("inf", "1/0", None)

# A realistic player row, shaped exactly like the mod builds one.
player = '''{
  name = "Hans", is_bot = true, bandit_id_crc = 123456, won = true,
  events = { Kill = 3 },
  breakdown = array({
    {event="Kill", event_id=2, raw_count=3, counted=3, mp_each=2, mp=6},
    {event="MatchWin", event_id=-1, raw_count=1, counted=1, mp_each=7, mp=7},
  }),
  mp = 13,
}'''
out = L.eval("json_encode(%s)" % player)
p = json.loads(out)
assert p["mp"] == 13 and p["is_bot"] is True and len(p["breakdown"]) == 2, p
assert p["breakdown"][0]["event"] == "Kill", p
print("ok   %-28s %s" % ("player row", out[:90]))

# Key ordering must be stable across encodes so stored payloads diff cleanly.
a = L.eval('json_encode({z=1,a=2,m=3,k=4})')
b = L.eval('json_encode({k=4,m=3,a=2,z=1})')
assert a == b, (a, b)
print("ok   %-28s %s" % ("stable key order", a))

print("\nALL PASS" if ok else "\nFAILURES ABOVE")
sys.exit(0 if ok else 1)
